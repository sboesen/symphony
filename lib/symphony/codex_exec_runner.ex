defmodule Symphony.CodexExecRunner do
  @moduledoc "Runs one turn through `codex exec --json`."
  @log_rel_path ".git/symphony/codex-exec-raw.jsonl"
  @workspace_contract_grace_ms 2_000

  alias Symphony.{CompletionResult, PlanContract}

  def run_turn(workspace_path, config, _issue, _attempt, prompt, routing, on_update)
      when is_function(on_update, 1) do
    deadline = System.monotonic_time(:millisecond) + max(1, config.turn_timeout_ms)
    read_timeout = max(100, config.read_timeout_ms)
    model = resolve_model(routing[:model] || config.codex_model)
    {exe, base_args} = command_parts(config.codex_command)
    args = codex_args(base_args, model, config)
    shell_command = build_shell_command(exe, args)

    port =
      Port.open(
        {:spawn_executable, System.find_executable("bash") || "/bin/bash"},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, ["-lc", shell_command]},
          {:cd, workspace_path},
          {:env, codex_env(config, prompt)}
        ]
      )

    state = %{
      port: port,
      workspace_path: workspace_path,
      phase: infer_phase(prompt),
      deadline_ms: deadline,
      read_timeout_ms: read_timeout,
      stall_timeout_ms: max(read_timeout, config.stall_timeout_ms || 300_000),
      usage: %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
      queue: [],
      buffer: "",
      thread_id: nil,
      last_activity_ms: System.monotonic_time(:millisecond),
      contract_ready_ms: nil,
      terminal_reason: nil,
      error: nil
    }

    state = write_log_banner(state, prompt, model)

    case await_completion(state, on_update) do
      {:ok, status, state} ->
        close_port(port)
        _ = append_log_line(state, %{type: "runner.exit_status", status: status})

        cond do
          status != 0 -> {:error, {:codex_exec_exit_status, status}}
          state.error != nil -> {:error, state.error}
          true -> {:ok, %{usage: state.usage, session_id: state.thread_id}}
        end

      {:error, reason} ->
        close_port(port)
        _ = append_log_line(state, %{type: "runner.error", reason: inspect(reason)})
        {:error, reason}
    end
  end

  defp await_completion(state, on_update) do
    cond do
      state.terminal_reason == :stop ->
        {:ok, 0, state}

      System.monotonic_time(:millisecond) >= state.deadline_ms ->
        {:error, :turn_timeout}

      stalled?(state) ->
        {:error, :stall_timeout}

      true ->
        state = process_queue(state, on_update) |> maybe_complete_from_workspace_contract()

        receive do
          {port, {:data, data}} when port == state.port ->
            await_completion(enqueue_data(state, data), on_update)

          {port, {:exit_status, status}} when port == state.port ->
            final_state = process_queue(state, on_update)
            {:ok, status, final_state}
        after
          state.read_timeout_ms ->
            state = maybe_complete_from_workspace_contract(state)

            case state.terminal_reason do
              :stop -> {:ok, 0, state}
              _ -> await_completion(state, on_update)
            end
        end
    end
  end

  defp process_queue(state, on_update) do
    Enum.reduce(state.queue, %{state | queue: []}, fn line, acc ->
      _ = append_log_line(acc, line)

      case Jason.decode(line) do
        {:ok, payload} when is_map(payload) ->
          next = apply_payload(acc, payload, on_update)
          next

        _ ->
          if String.trim(line) != "" do
            on_update.(%{type: :codex_stdout, line: line, usage: acc.usage})
          end

          acc
      end
    end)
  end

  defp apply_payload(state, payload, on_update) do
    thread_id = payload["thread_id"] || state.thread_id
    usage = payload_usage(payload, state.usage)
    state = %{state | thread_id: thread_id, usage: usage}

    on_update.(%{
      type: :codex_update,
      payload: payload,
      usage: usage,
      thread_id: thread_id,
      turn_id: nil,
      session_id: thread_id
    })

    case payload["type"] do
      "item.completed" ->
        case get_in(payload, ["item", "type"]) do
          "agent_message" ->
            text = get_in(payload, ["item", "text"]) || line_fallback(payload)
            on_update.(%{type: :codex_stdout, line: text, usage: usage})
            state

          _ ->
            state
        end

      "turn.completed" ->
        %{state | terminal_reason: :stop}

      "turn.failed" ->
        %{state | error: {:codex_exec_failed, payload}, terminal_reason: :stop}

      "error" ->
        %{state | error: {:codex_exec_error, payload}, terminal_reason: :stop}

      _ ->
        state
    end
  end

  defp line_fallback(payload), do: Jason.encode!(payload)

  defp payload_usage(payload, fallback) do
    usage = payload["usage"] || %{}

    if map_size(usage) == 0 do
      fallback
    else
      %{
        input_tokens: to_int(usage["input_tokens"] || usage["inputTokens"]),
        output_tokens: to_int(usage["output_tokens"] || usage["outputTokens"]),
        total_tokens:
          to_int(
            usage["total_tokens"] || usage["totalTokens"] ||
              to_int(usage["input_tokens"] || usage["inputTokens"]) +
                to_int(usage["output_tokens"] || usage["outputTokens"])
          )
      }
    end
  end

  defp enqueue_data(state, data) do
    chunk = to_binary_chunk(data)
    text = state.buffer <> chunk

    {lines, buffer} =
      case String.ends_with?(text, "\n") do
        true ->
          {String.split(text, "\n", trim: true), ""}

        false ->
          parts = String.split(text, "\n")
          {Enum.drop(parts, -1) |> Enum.reject(&(&1 == "")), List.last(parts) || ""}
      end

    %{
      state
      | queue: state.queue ++ lines,
        buffer: buffer,
        last_activity_ms: System.monotonic_time(:millisecond)
    }
  end

  defp to_binary_chunk({:eol, line}), do: IO.iodata_to_binary(line) <> "\n"
  defp to_binary_chunk({:noeol, line}), do: IO.iodata_to_binary(line)
  defp to_binary_chunk(data) when is_binary(data), do: data
  defp to_binary_chunk(data), do: IO.iodata_to_binary(data)

  defp close_port(port) do
    if is_port(port) and Port.info(port) != nil do
      Port.close(port)
    end
  end

  defp write_log_banner(state, prompt, model) do
    _ = File.mkdir_p!(Path.dirname(log_path(state.workspace_path)))
    _ = File.write(log_path(state.workspace_path), "")

    _ =
      append_log_line(state, %{
        type: "runner.start",
        model: model,
        started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        prompt_preview: String.slice(prompt || "", 0, 500)
      })

    state
  end

  defp append_log_line(%{workspace_path: workspace_path}, line) do
    path = log_path(workspace_path)

    rendered =
      case line do
        value when is_binary(value) -> value
        value when is_map(value) -> Jason.encode!(value)
        value -> inspect(value)
      end

    File.write(path, rendered <> "\n", [:append])
  end

  defp log_path(workspace_path), do: Path.join(workspace_path, @log_rel_path)

  defp maybe_complete_from_workspace_contract(%{terminal_reason: :stop} = state), do: state

  defp maybe_complete_from_workspace_contract(state) do
    if workspace_contract_satisfied?(state.workspace_path, state.phase) do
      now = System.monotonic_time(:millisecond)

      case state.contract_ready_ms do
        nil ->
          %{state | contract_ready_ms: now}

        ready_ms when now - ready_ms >= @workspace_contract_grace_ms ->
          append_log_line(state, %{type: "runner.workspace_contract_complete"}) |> ignore_result()
          %{state | terminal_reason: :stop}

        _ ->
          state
      end
    else
      %{state | contract_ready_ms: nil}
    end
  end

  defp workspace_contract_satisfied?(workspace_path, phase) do
    case phase do
      :plan ->
        valid_plan_contract?(workspace_path)

      :execution ->
        valid_execution_contract?(workspace_path)

      _ ->
        false
    end
  end

  defp valid_plan_contract?(workspace_path) do
    with {:ok, plan} <- PlanContract.load(workspace_path),
         true <- PlanContract.has_steps?(plan) do
      true
    else
      _ -> false
    end
  end

  defp valid_execution_contract?(workspace_path) do
    with {:ok, plan} <- PlanContract.load(workspace_path),
         true <- PlanContract.has_steps?(plan),
         true <- PlanContract.all_done?(plan),
         {:ok, result} <- CompletionResult.load(workspace_path),
         true <- valid_completion_contract?(workspace_path, result) do
      true
    else
      _ -> false
    end
  end

  defp valid_completion_contract?(workspace_path, %{status: "completed"}) do
    File.exists?(Path.join(workspace_path, ".git/symphony/demo-plan.json"))
  end

  defp valid_completion_contract?(_workspace_path, %{status: status})
       when status in ["needs_more_work", "blocked"],
       do: true

  defp valid_completion_contract?(_workspace_path, _result), do: false

  defp infer_phase(prompt) when is_binary(prompt) do
    cond do
      String.starts_with?(
        prompt,
        "Create the execution plan for this issue before implementation."
      ) ->
        :plan

      String.starts_with?(
        prompt,
        "The Symphony execution plan does not match the issue target closely enough."
      ) ->
        :plan

      String.contains?(prompt, "Update only `.git/symphony/plan.json`.") ->
        :plan

      true ->
        :execution
    end
  end

  defp infer_phase(_prompt), do: :execution

  defp ignore_result(_value), do: :ok

  defp stalled?(state) do
    System.monotonic_time(:millisecond) - state.last_activity_ms >= state.stall_timeout_ms
  end

  defp command_parts(command) do
    parts = command |> to_string() |> String.split(~r/\s+/, trim: true)

    case parts do
      [] -> {"codex", []}
      [exe] -> {exe, []}
      [exe | args] -> {exe, args}
    end
  end

  defp codex_args(base_args, model, config) do
    base_args
    |> ensure_contains("exec")
    |> ensure_option("--json", nil)
    |> ensure_option("--model", model)
    |> ensure_option("--ask-for-approval", config_value(config, :approval_policy))
    |> ensure_option("--sandbox", exec_sandbox(config))
  end

  defp ensure_contains(args, token) do
    if token in args, do: args, else: [token | args]
  end

  defp ensure_option(args, key, nil) do
    if key in args, do: args, else: args ++ [key]
  end

  defp ensure_option(args, key, value) do
    if key in args, do: args, else: args ++ [key, value]
  end

  defp config_value(config, key) when is_map(config), do: Map.get(config, key)
  defp config_value(_config, _key), do: nil

  defp exec_sandbox(config) do
    config_value(config, :turn_sandbox_policy) || config_value(config, :thread_sandbox)
  end

  defp build_shell_command(exe, args) do
    escaped_exe = shell_escape(exe)
    escaped_args = args |> Enum.map(&shell_escape/1) |> Enum.join(" ")
    "#{escaped_exe} #{escaped_args} \"$SYMPHONY_PROMPT\" < /dev/null"
  end

  defp shell_escape(value) do
    escaped = value |> to_string() |> String.replace("'", "'\"'\"'")
    "'" <> escaped <> "'"
  end

  defp codex_env(config, prompt) do
    env =
      System.get_env()
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        if key in ["OPENAI_API_KEY", "OPENAI_BASE_URL", "Z_API_KEY"] do
          acc
        else
          if is_binary(value) and String.trim(value) != "" do
            Map.put(acc, key, value)
          else
            acc
          end
        end
      end)

    env
    |> maybe_put_env("OPENAI_API_KEY", config.openai_api_key)
    |> Map.put("SYMPHONY_PROMPT", prompt)
    |> Enum.map(fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end

  defp maybe_put_env(env, _key, nil), do: env

  defp maybe_put_env(env, key, value) when is_binary(value) do
    normalized = String.trim(value)
    if normalized == "", do: env, else: Map.put(env, key, normalized)
  end

  defp maybe_put_env(env, _key, _), do: env

  defp resolve_model(nil), do: "gpt-5-codex"

  defp resolve_model(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace_prefix("openai/", "")
  end

  defp resolve_model(value), do: to_string(value)

  defp to_int(nil), do: 0
  defp to_int(v) when is_integer(v), do: v

  defp to_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      _ -> 0
    end
  end

  defp to_int(_), do: 0
end
