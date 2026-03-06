defmodule Symphony.CodexAppServer do
  @moduledoc "Minimal Codex app-server JSON-RPC client over stdio."

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3

  def run_turn(workspace_path, config, _issue, _attempt, prompt, routing, on_update)
      when is_function(on_update, 1) do
    deadline = System.monotonic_time(:millisecond) + max(1, config.turn_timeout_ms)

    port =
      Port.open(
        {:spawn_executable, System.find_executable("bash") || "/bin/bash"},
        [
          :binary,
          :exit_status,
          {:args, ["-lc", config.codex_command]},
          {:cd, workspace_path},
          {:env, codex_env(config, routing)}
        ]
      )

    state = %{
      port: port,
      deadline_ms: deadline,
      read_timeout_ms: max(100, config.read_timeout_ms),
      usage: %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
      queue: [],
      buffer: "",
      thread_id: nil,
      turn_id: nil,
      session_id: nil
    }

    with :ok <- send_json(port, initialize_payload()),
         :ok <- send_json(port, initialized_payload()),
         :ok <- send_json(port, thread_start_payload(config, routing)),
         {:ok, state} <- await_thread_start(state, on_update),
         :ok <- send_json(port, turn_start_payload(state.thread_id, prompt, config, routing)),
         {:ok, state} <- await_turn_completion(state, on_update) do
      close_port(port)
      {:ok, %{usage: state.usage, session_id: state.session_id}}
    else
      {:error, reason} ->
        close_port(port)
        {:error, reason}
    end
  end

  def run_turn(workspace_path, config, _issue, _attempt, prompt, on_update) do
    routing = %{
      provider: config.codex_router_default_provider || "zai",
      model: config.codex_model,
      model_provider: config.codex_model_provider,
      effort: config.codex_reasoning_effort
    }

    run_turn(workspace_path, config, nil, nil, prompt, routing, on_update)
  end

  defp await_thread_start(state, on_update) do
    case next_payload(state) do
      {:ok, payload, state} ->
        state = apply_payload(state, payload, on_update)

        cond do
          response_id(payload) == @thread_start_id ->
            case extract_thread_id(payload) do
              nil -> {:error, :thread_start_missing_thread_id}
              thread_id ->
                state = update_session(state, thread_id, state.turn_id)
                on_update.(%{event: :session_started, thread_id: thread_id, turn_id: state.turn_id, session_id: state.session_id})
                {:ok, state}
            end

          error_id(payload) == @thread_start_id ->
            {:error, {:thread_start_failed, payload["error"]}}

          true ->
            await_thread_start(state, on_update)
        end

      {:raw, line, state} ->
        on_update.(%{type: :codex_stdout, line: line, usage: state.usage})
        await_thread_start(state, on_update)

      {:timeout, state} ->
        if expired?(state), do: {:error, :turn_timeout}, else: await_thread_start(state, on_update)

      {:exit_ok, state} ->
        {:error, {:codex_exit_before_thread_start, state.usage}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp await_turn_completion(state, on_update) do
    case next_payload(state) do
      {:ok, payload, state} ->
        state = apply_payload(state, payload, on_update)

        cond do
          error_id(payload) == @turn_start_id ->
            {:error, {:turn_start_failed, payload["error"]}}

          turn_completed?(payload) ->
            case turn_status(payload) do
              nil -> {:ok, state}
              "completed" -> {:ok, state}
              "interrupted" -> {:error, :turn_interrupted}
              other -> {:error, {:turn_failed, other, turn_error(payload)}}
            end

          true ->
            await_turn_completion(state, on_update)
        end

      {:raw, line, state} ->
        on_update.(%{type: :codex_stdout, line: line, usage: state.usage})
        await_turn_completion(state, on_update)

      {:timeout, state} ->
        if expired?(state), do: {:error, :turn_timeout}, else: await_turn_completion(state, on_update)

      {:exit_ok, state} ->
        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp expired?(state) do
    System.monotonic_time(:millisecond) >= state.deadline_ms
  end

  defp next_payload(state) do
    case state.queue do
      [line | rest] ->
        state = %{state | queue: rest}

        case Jason.decode(line) do
          {:ok, payload} when is_map(payload) -> {:ok, payload, state}
          _ -> {:raw, line, state}
        end

      [] ->
        if expired?(state) do
          {:error, :turn_timeout}
        else
          receive do
            {port, {:data, data}} when port == state.port ->
              next_payload(enqueue_data(state, data))

            {port, {:exit_status, 0}} when port == state.port ->
              {:exit_ok, state}

            {port, {:exit_status, status}} when port == state.port ->
              {:error, {:codex_exit_status, status}}
          after
            state.read_timeout_ms ->
              {:timeout, state}
          end
        end
    end
  end

  defp enqueue_data(state, data) do
    chunk = to_binary_chunk(data)
    text = state.buffer <> chunk

    {lines, buffer} =
      case String.ends_with?(text, "\n") do
        true -> {String.split(text, "\n", trim: true), ""}
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

  defp apply_payload(state, payload, on_update) do
    state = maybe_handle_server_request(state, payload)
    usage = extract_usage(payload, state.usage)
    thread_id = extract_thread_id(payload) || state.thread_id
    turn_id = extract_turn_id(payload) || state.turn_id

    state =
      state
      |> Map.put(:usage, usage)
      |> update_session(thread_id, turn_id)

    on_update.(%{
      type: :codex_update,
      payload: payload,
      usage: usage,
      thread_id: state.thread_id,
      turn_id: state.turn_id,
      session_id: state.session_id
    })

    state
  end

  defp maybe_handle_server_request(state, payload) do
    if server_request?(payload) do
      _ =
        send_json(state.port, %{
          jsonrpc: "2.0",
          id: payload["id"],
          error: %{code: -32601, message: "unsupported client callback in Symphony runner"}
        })

      state
    else
      state
    end
  end

  defp update_session(state, thread_id, turn_id) do
    session_id = if is_binary(thread_id) and is_binary(turn_id), do: "#{thread_id}-#{turn_id}", else: nil

    %{state | thread_id: thread_id, turn_id: turn_id, session_id: session_id}
  end

  defp response_id(payload), do: payload["id"]

  defp server_request?(payload) do
    Map.has_key?(payload, "id") and
      Map.has_key?(payload, "method") and
      not Map.has_key?(payload, "result") and
      not Map.has_key?(payload, "error")
  end

  defp error_id(payload) do
    if Map.has_key?(payload, "error"), do: payload["id"], else: nil
  end

  defp extract_thread_id(payload) do
    get_in(payload, ["result", "thread", "id"]) ||
      get_in(payload, ["params", "thread", "id"]) ||
      get_in(payload, ["result", "threadId"]) ||
      get_in(payload, ["params", "threadId"])
  end

  defp extract_turn_id(payload) do
    get_in(payload, ["result", "turn", "id"]) ||
      get_in(payload, ["params", "turn", "id"]) ||
      get_in(payload, ["result", "turnId"]) ||
      get_in(payload, ["params", "turnId"])
  end

  defp turn_completed?(payload), do: payload["method"] == "turn/completed"

  defp turn_status(payload) do
    get_in(payload, ["params", "turn", "status"]) ||
      get_in(payload, ["params", "status"])
  end

  defp turn_error(payload) do
    get_in(payload, ["params", "turn", "error"]) ||
      get_in(payload, ["params", "error"])
  end

  defp extract_usage(payload, fallback) do
    usage_source =
      get_in(payload, ["params", "tokenUsage", "last"]) ||
        get_in(payload, ["result", "thread", "tokenUsage", "last"]) ||
        get_in(payload, ["params", "usage"]) ||
        %{}

    if map_size(usage_source) == 0 do
      fallback
    else
      %{
        input_tokens: to_int(usage_source["inputTokens"] || usage_source["input_tokens"]),
        output_tokens: to_int(usage_source["outputTokens"] || usage_source["output_tokens"]),
        total_tokens:
          to_int(
            usage_source["totalTokens"] || usage_source["total_tokens"] ||
              (to_int(usage_source["inputTokens"] || usage_source["input_tokens"]) +
                 to_int(usage_source["outputTokens"] || usage_source["output_tokens"]))
          )
      }
    end
  end

  defp to_int(nil), do: 0
  defp to_int(v) when is_integer(v), do: v

  defp to_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      _ -> 0
    end
  end

  defp to_int(_), do: 0

  defp initialize_payload do
    %{
      jsonrpc: "2.0",
      id: @initialize_id,
      method: "initialize",
      params: %{clientInfo: %{name: "symphony", version: "0.1.0"}}
    }
  end

  defp initialized_payload do
    %{jsonrpc: "2.0", method: "initialized", params: %{}}
  end

  defp thread_start_payload(config, routing) do
    params =
      %{}
      |> maybe_put("approvalPolicy", config.approval_policy)
      |> maybe_put("sandbox", config.thread_sandbox)
      |> maybe_put("model", routing[:model] || config.codex_model)
      |> maybe_put("modelProvider", routing[:model_provider] || config.codex_model_provider)

    %{jsonrpc: "2.0", id: @thread_start_id, method: "thread/start", params: params}
  end

  defp turn_start_payload(thread_id, prompt, config, routing) do
    params =
      %{
        "threadId" => thread_id,
        "input" => [%{"type" => "text", "text" => prompt}]
      }
      |> maybe_put("approvalPolicy", config.approval_policy)
      |> maybe_put("sandboxPolicy", config.turn_sandbox_policy)
      |> maybe_put("model", routing[:model] || config.codex_model)
      |> maybe_put("effort", routing[:effort])

    %{jsonrpc: "2.0", id: @turn_start_id, method: "turn/start", params: params}
  end

  defp send_json(port, payload) do
    case Jason.encode(payload) do
      {:ok, encoded} ->
        Port.command(port, encoded <> "\n")
        :ok

      _ ->
        {:error, :json_encode_error}
    end
  end

  defp close_port(port) do
    if is_port(port) and Port.info(port) != nil do
      Port.close(port)
    end
  end

  defp codex_env(config, routing) do
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

  defp maybe_put(map, _key, nil), do: map

  defp maybe_put(map, key, value) when is_binary(value) do
    normalized = String.trim(value)
    if normalized == "", do: map, else: Map.put(map, key, normalized)
  end

  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_env(env, _key, nil), do: env

  defp maybe_put_env(env, key, value) when is_binary(value) do
    normalized = String.trim(value)
    if normalized == "", do: env, else: Map.put(env, key, normalized)
  end

  defp maybe_put_env(env, _key, _), do: env
end
