defmodule Symphony.OpenCodeRunner do
  @moduledoc "Runs one turn through OpenCode CLI and streams JSON events."

  def run_turn(workspace_path, config, _issue, _attempt, prompt, routing, on_update)
      when is_function(on_update, 1) do
    deadline = System.monotonic_time(:millisecond) + max(1, config.turn_timeout_ms)
    read_timeout = max(100, config.read_timeout_ms)
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
          {:env, opencode_env(config, routing, prompt)}
        ]
      )

    state = %{
      port: port,
      deadline_ms: deadline,
      read_timeout_ms: read_timeout,
      usage: %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
      queue: [],
      buffer: "",
      session_id: nil,
      error: nil,
      terminal_reason: nil
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
      true ->
        state = process_queue(state, on_update)

        receive do
          {port, {:data, data}} when port == state.port ->
            await_completion(enqueue_data(state, data), on_update)

          {port, {:exit_status, status}} when port == state.port ->
            final_state = process_queue(state, on_update)
            {:ok, status, final_state}
        after
          state.read_timeout_ms ->
            if state.terminal_reason == :stop do
              {:ok, 0, state}
            else
              await_completion(state, on_update)
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
              (to_int(tokens["input"] || tokens["inputTokens"]) +
                 to_int(tokens["output"] || tokens["outputTokens"]))
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

    %{state | queue: state.queue ++ lines, buffer: buffer}
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
      String.contains?(normalized, "/") ->
        normalized

      lower in ["glm-5", "glm5"] ->
        "zai-coding-plan/glm-5"

      lower in ["glm-4.7", "glm47"] ->
        "zai-coding-plan/glm-4.7"

      lower in ["codex-5-3", "gpt-5.3-codex"] ->
        "openai/gpt-5.3-codex"

      lower in ["codex-5-3-spark", "gpt-5.3-codex-spark"] ->
        "openai/gpt-5.3-codex-spark"

      to_string(provider) == "codex" ->
        "openai/#{lower}"

      true ->
        "zai-coding-plan/#{lower}"
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

  defp opencode_env(config, routing, prompt) do
    profile = provider_profile(config, routing)
    auth_mode = resolve_auth_mode(profile)

    env =
      System.get_env()
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        if is_binary(value) and String.trim(value) != "" do
          Map.put(acc, key, value)
        else
          acc
        end
      end)

    env
    |> maybe_put_env("OPENAI_API_KEY", api_key_for_env(profile, config, auth_mode))
    |> maybe_put_env("Z_API_KEY", z_api_key_for_env(profile, config, auth_mode))
    |> maybe_put_env("OPENAI_BASE_URL", base_url_for_env(profile, config, auth_mode))
    |> Map.merge(profile[:env] || %{})
    |> Map.put("SYMPHONY_PROMPT", prompt)
    |> Enum.map(fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end

  defp provider_profile(config, routing) do
    provider_name = to_string(routing[:provider] || config.codex_router_default_provider || "zai")
    configured = Map.get(config.codex_profiles || %{}, provider_name, %{})

    %{
      name: provider_name,
      api_key: Map.get(configured, :api_key, config.openai_api_key),
      z_api_key: Map.get(configured, :z_api_key, config.zai_api_key),
      base_url: Map.get(configured, :base_url, config.openai_base_url),
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
