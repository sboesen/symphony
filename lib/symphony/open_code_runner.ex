defmodule Symphony.OpenCodeRunner do
  @moduledoc "Runs one turn through OpenCode CLI and streams JSON events."
  @workspace_contract_grace_ms 2_000

  alias Symphony.{CompletionResult, PlanContract}

  def run_turn(workspace_path, config, _issue, _attempt, prompt, routing, on_update)
      when is_function(on_update, 1) do
    deadline = System.monotonic_time(:millisecond) + max(1, config.turn_timeout_ms)
    read_timeout = max(100, config.read_timeout_ms)
    stall_timeout = max(read_timeout, config.stall_timeout_ms || 300_000)
    model = resolve_model(routing[:model] || config.codex_model, routing[:provider])
    variant = resolve_variant(routing[:effort])
    {exe, base_args} = command_parts(config.codex_command)
    args = opencode_args(base_args, model, variant)
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
          {:env, opencode_env(workspace_path, config, routing, prompt)}
        ]
      )

    state = %{
      port: port,
      workspace_path: workspace_path,
      phase: infer_phase(prompt),
      deadline_ms: deadline,
      read_timeout_ms: read_timeout,
      usage: %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
      queue: [],
      buffer: "",
      session_id: nil,
      error: nil,
      terminal_reason: nil,
      stall_timeout_ms: stall_timeout,
      last_activity_ms: System.monotonic_time(:millisecond),
      contract_ready_ms: nil
    }

    case await_completion(state, on_update) do
      {:ok, status, state} ->
        close_port(port)

        cond do
          status != 0 ->
            {:error, {:opencode_exit_status, status}}

          state.terminal_reason == :stop ->
            {:ok, %{usage: state.usage, session_id: state.session_id}}

          state.error != nil ->
            {:error, {:opencode_error, state.error}}

          true ->
            {:ok, %{usage: state.usage, session_id: state.session_id}}
        end

      {:error, reason} ->
        close_port(port)
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

        if state.terminal_reason == :stop do
          {:ok, 0, state}
        else
          receive do
            {port, {:data, data}} when port == state.port ->
              await_completion(enqueue_data(state, data), on_update)

            {port, {:exit_status, status}} when port == state.port ->
              final_state = process_queue(state, on_update)
              {:ok, status, final_state}
          after
            state.read_timeout_ms ->
              state = maybe_complete_from_workspace_contract(state)

              if state.terminal_reason == :stop do
                {:ok, 0, state}
              else
                await_completion(state, on_update)
              end
          end
        end
    end
  end

  defp process_queue(state, on_update) do
    Enum.reduce(state.queue, %{state | queue: []}, fn line, acc ->
      case Jason.decode(line) do
        {:ok, payload} when is_map(payload) ->
          session_id = acc.session_id || payload["sessionID"]
          usage = opencode_usage(payload, acc.usage)
          next = %{acc | session_id: session_id, usage: usage}

          on_update.(%{
            type: :codex_update,
            payload: payload,
            usage: usage,
            thread_id: session_id,
            turn_id: nil,
            session_id: session_id
          })

          case payload["type"] do
            "text" ->
              text = get_in(payload, ["part", "text"]) || line
              on_update.(%{type: :codex_stdout, line: text, usage: usage})
              next

            "step_finish" ->
              case step_finish_reason(payload) do
                "stop" ->
                  %{next | terminal_reason: :stop, error: nil}

                "error" ->
                  %{next | error: payload}

                "interrupted" ->
                  %{next | error: payload}

                _ ->
                  next
              end

            "error" ->
              %{next | error: payload["error"] || payload}

            _ ->
              next
          end

        _ ->
          if String.trim(line) != "" do
            on_update.(%{type: :codex_stdout, line: line, usage: acc.usage})
          end

          acc
      end
    end)
  end

  defp opencode_usage(payload, fallback) do
    tokens = get_in(payload, ["part", "tokens"]) || %{}

    if map_size(tokens) == 0 do
      fallback
    else
      %{
        input_tokens: to_int(tokens["input"] || tokens["inputTokens"]),
        output_tokens: to_int(tokens["output"] || tokens["outputTokens"]),
        total_tokens:
          to_int(
            tokens["total"] || tokens["totalTokens"] ||
              to_int(tokens["input"] || tokens["inputTokens"]) +
                to_int(tokens["output"] || tokens["outputTokens"])
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

  defp stalled?(state) do
    System.monotonic_time(:millisecond) - state.last_activity_ms >= state.stall_timeout_ms
  end

  defp maybe_complete_from_workspace_contract(%{terminal_reason: :stop} = state), do: state

  defp maybe_complete_from_workspace_contract(state) do
    if workspace_contract_satisfied?(state.workspace_path, state.phase) do
      now = System.monotonic_time(:millisecond)

      case state.contract_ready_ms do
        nil ->
          %{state | contract_ready_ms: now}

        ready_ms when now - ready_ms >= @workspace_contract_grace_ms ->
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
         {:ok, result} <- CompletionResult.load(workspace_path),
         true <- valid_completion_contract?(workspace_path, plan, result) do
      true
    else
      _ -> false
    end
  end

  defp valid_completion_contract?(workspace_path, plan, %{status: "completed"}) do
    PlanContract.all_done?(plan) and
      File.exists?(Path.join(workspace_path, ".git/symphony/demo-plan.json"))
  end

  defp valid_completion_contract?(_workspace_path, _plan, %{status: status})
       when status in ["needs_more_work", "blocked"],
       do: true

  defp valid_completion_contract?(_workspace_path, _plan, _result), do: false

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

  defp close_port(port) do
    if is_port(port) and Port.info(port) != nil do
      Port.close(port)
    end
  end

  defp command_parts(command) do
    parts = command |> to_string() |> String.split(~r/\s+/, trim: true)

    case parts do
      [] -> {"opencode", ["run", "--format", "json"]}
      [exe] -> {exe, ["run", "--format", "json"]}
      [exe | args] -> {exe, args}
    end
  end

  defp opencode_args(base_args, model, variant) do
    args =
      base_args
      |> ensure_contains("run")
      |> ensure_option("--format", "json")
      |> ensure_option("--model", model)

    if is_binary(variant) and variant != "" do
      ensure_option(args, "--variant", variant)
    else
      args
    end
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

  defp ensure_contains(args, token) do
    if token in args, do: args, else: [token | args]
  end

  defp ensure_option(args, key, value) do
    if key in args do
      args
    else
      args ++ [key, value]
    end
  end

  defp resolve_model(nil, provider), do: resolve_model("GLM-5", provider)

  defp resolve_model(model, provider) when is_binary(model) do
    normalized = String.trim(model)
    lower = String.downcase(normalized)

    cond do
      String.starts_with?(lower, "zai-coding-plan/") ->
        normalized
        |> String.replace_prefix("zai-coding-plan/", "zai/")
        |> String.replace_prefix("ZAI-CODING-PLAN/", "zai/")

      String.contains?(normalized, "/") ->
        normalized

      lower in ["glm-5", "glm5"] ->
        "zai/glm-5"

      lower in ["glm-4.7", "glm47"] ->
        "zai/glm-4.7"

      lower in ["codex-5-3", "gpt-5.3-codex"] ->
        "openai/gpt-5.3-codex"

      lower in ["codex-5-3-spark", "gpt-5.3-codex-spark"] ->
        "openai/gpt-5.3-codex-spark"

      to_string(provider) == "codex" ->
        "openai/#{lower}"

      true ->
        "zai/#{lower}"
    end
  end

  defp resolve_model(model, _provider), do: to_string(model)

  defp resolve_variant(nil), do: nil
  defp resolve_variant("xhigh"), do: "max"
  defp resolve_variant("high"), do: "high"
  defp resolve_variant("medium"), do: "medium"
  defp resolve_variant("low"), do: "low"
  defp resolve_variant(value) when is_binary(value), do: String.trim(value)
  defp resolve_variant(_), do: nil

  defp opencode_env(workspace_path, config, routing, prompt) do
    profile = provider_profile(config, routing)
    auth_mode = resolve_auth_mode(profile)

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

    env =
      env
      |> maybe_put_env("OPENAI_API_KEY", api_key_for_env(profile, config, auth_mode))
      |> maybe_put_env("Z_API_KEY", z_api_key_for_env(profile, config, auth_mode))
      |> maybe_put_env("OPENAI_BASE_URL", base_url_for_env(profile, config, auth_mode))
      |> Map.merge(profile[:env] || %{})
      |> Map.put("SYMPHONY_PROMPT", prompt)

    Symphony.OpenCodeRuntime.build_env(workspace_path, env, %{
      model: resolve_model(profile[:model], profile[:name]),
      provider_id: provider_id(profile[:name], profile[:model]),
      api_key:
        profile[:z_api_key] || profile[:api_key] || config.zai_api_key || config.openai_api_key,
      base_url: base_url_for_env(profile, config, auth_mode)
    })
    |> Enum.map(fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end

  defp provider_profile(config, routing) do
    provider_name = to_string(routing[:provider] || config.codex_router_default_provider || "zai")
    configured = Map.get(config.codex_profiles || %{}, provider_name, %{})

    %{
      name: provider_name,
      api_key: Map.get(configured, :api_key, config.openai_api_key),
      z_api_key:
        Map.get_lazy(configured, :z_api_key, fn ->
          if provider_name == "zai", do: config.zai_api_key, else: nil
        end),
      base_url:
        Map.get_lazy(configured, :base_url, fn ->
          if provider_name == "zai", do: config.openai_base_url, else: nil
        end),
      model_provider: Map.get(configured, :model_provider, config.codex_model_provider),
      model: Map.get(configured, :model, config.codex_model),
      auth_mode: Map.get(configured, :auth_mode),
      env: Map.get(configured, :env, %{})
    }
  end

  defp resolve_auth_mode(profile) do
    profile[:auth_mode] ||
      if(profile[:api_key] || profile[:z_api_key], do: "api_key", else: "app_server")
  end

  defp api_key_for_env(_profile, _config, "app_server"), do: nil
  defp api_key_for_env(profile, config, _), do: profile[:api_key] || config.openai_api_key

  defp z_api_key_for_env(_profile, _config, "app_server"), do: nil
  defp z_api_key_for_env(profile, config, _), do: profile[:z_api_key] || config.zai_api_key

  defp base_url_for_env(_profile, _config, "app_server"), do: nil
  defp base_url_for_env(profile, config, _), do: profile[:base_url] || config.openai_base_url

  defp maybe_put_env(env, _key, nil), do: env

  defp maybe_put_env(env, key, value) when is_binary(value) do
    normalized = String.trim(value)
    if normalized == "", do: env, else: Map.put(env, key, normalized)
  end

  defp maybe_put_env(env, _key, _), do: env

  defp provider_id(name, model) when is_binary(model) do
    case String.split(model, "/", parts: 2) do
      [provider, _] when provider != "" -> provider
      _ -> provider_id(name, nil)
    end
  end

  defp provider_id("zai", _), do: "zai"
  defp provider_id("codex", _), do: "openai"
  defp provider_id(name, _) when is_binary(name), do: name
  defp provider_id(_, _), do: nil

  defp to_int(nil), do: 0
  defp to_int(v) when is_integer(v), do: v

  defp to_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      _ -> 0
    end
  end

  defp to_int(_), do: 0

  defp step_finish_reason(payload) do
    get_in(payload, ["part", "reason"])
  end
end
