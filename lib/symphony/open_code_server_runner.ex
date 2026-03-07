defmodule Symphony.OpenCodeServerRunner do
  @moduledoc "Runs one turn through OpenCode headless HTTP server (`opencode serve`)."

  @default_host "127.0.0.1"

  def run_turn(workspace_path, config, issue, _attempt, prompt, routing, on_update)
      when is_function(on_update, 1) do
    deadline_ms = System.monotonic_time(:millisecond) + max(1, config.turn_timeout_ms)
    read_timeout_ms = max(1_000, config.read_timeout_ms)
    serve_port = pick_available_port()
    serve_url = "http://#{@default_host}:#{serve_port}"
    server_command = build_server_command(config.codex_command, serve_port)

    port =
      Port.open(
        {:spawn_executable, System.find_executable("bash") || "/bin/bash"},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, ["-lc", server_command]},
          {:cd, workspace_path},
          {:env, opencode_env(config, routing)}
        ]
      )

    result =
      with :ok <- wait_for_health(serve_url, deadline_ms, read_timeout_ms),
           {:ok, session} <- create_session(serve_url, workspace_path, issue, read_timeout_ms, deadline_ms),
           {:ok, session_id} <- extract_session_id(session) do
        _ = emit_session_started(on_update, session_id)

        case send_prompt_async(
               serve_url,
               workspace_path,
               session_id,
               prompt,
               routing,
               config,
               read_timeout_ms,
               deadline_ms
             ) do
          :ok ->
            case wait_for_terminal_response(
                   serve_url,
                   workspace_path,
                   session_id,
                   read_timeout_ms,
                   deadline_ms
                 ) do
              {:ok, response} ->
                with {:ok, usage} <- extract_usage(response),
                     :ok <- emit_response_parts(on_update, response, usage, session_id),
                     :ok <- ensure_success_response(response) do
                  {:ok, %{usage: usage, session_id: session_id}}
                else
                  {:error, reason} ->
                    _ = abort_session(serve_url, workspace_path, session_id, read_timeout_ms)
                    {:error, reason}
                end

              {:error, reason} ->
                case recover_from_failure(
                       reason,
                       serve_url,
                       workspace_path,
                       session_id,
                       read_timeout_ms,
                       on_update
                     ) do
                  {:ok, usage} ->
                    {:ok, %{usage: usage, session_id: session_id}}

                  :error ->
                    _ = abort_session(serve_url, workspace_path, session_id, read_timeout_ms)
                    {:error, reason}
                end
            end

          {:error, reason} ->
            _ = abort_session(serve_url, workspace_path, session_id, read_timeout_ms)
            {:error, reason}
        end
      else
        {:error, reason} -> {:error, reason}
      end

    _ = dispose_server(serve_url, read_timeout_ms)
    close_port(port)
    result
  end

  defp recover_from_failure(
         _reason,
         base_url,
         workspace_path,
         session_id,
         read_timeout_ms,
         on_update
       ) do
    case fetch_latest_completed_assistant_message_with_retry(
           base_url,
           workspace_path,
           session_id,
           read_timeout_ms,
           6
         ) do
      {:ok, response} ->
        with {:ok, usage} <- extract_usage(response),
             :ok <- emit_response_parts(on_update, response, usage, session_id),
             :ok <- ensure_success_response(response, ["stop", "completed", "tool-calls"]) do
          {:ok, usage}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp wait_for_terminal_response(base_url, workspace_path, session_id, read_timeout_ms, deadline_ms) do
    if remaining_ms(deadline_ms) <= 0 do
      {:error, :turn_timeout}
    else
      case fetch_latest_completed_assistant_message(
             base_url,
             workspace_path,
             session_id,
             read_timeout_ms
           ) do
        {:ok, response} ->
          if terminal_finish?(response) do
            {:ok, response}
          else
            Process.sleep(500)

            wait_for_terminal_response(
              base_url,
              workspace_path,
              session_id,
              read_timeout_ms,
              deadline_ms
            )
          end

        :error ->
          case fetch_session_state(base_url, workspace_path, session_id, read_timeout_ms, deadline_ms) do
            {:ok, "error"} ->
              {:error, :opencode_server_session_error}

            _ ->
              Process.sleep(500)
              wait_for_terminal_response(
                base_url,
                workspace_path,
                session_id,
                read_timeout_ms,
                deadline_ms
              )
          end
      end
    end
  end

  defp terminal_finish?(response) when is_map(response) do
    info = response["info"] || %{}

    case info["finish"] do
      "stop" -> true
      "completed" -> true
      _ -> not is_nil(info["error"])
    end
  end

  defp terminal_finish?(_), do: false

  defp fetch_session_state(base_url, workspace_path, session_id, read_timeout_ms, deadline_ms) do
    url = base_url <> "/session/status?directory=" <> URI.encode_www_form(workspace_path)

    case get_json(url, read_timeout_ms, deadline_ms) do
      {:ok, payload} when is_map(payload) ->
        case get_in(payload, [session_id, "type"]) do
          state when is_binary(state) -> {:ok, state}
          _ -> :error
        end

      {:error, _} ->
        :error
    end
  end

  defp fetch_latest_completed_assistant_message_with_retry(
         base_url,
         workspace_path,
         session_id,
         read_timeout_ms,
         attempts_left
       ) do
    case fetch_latest_completed_assistant_message(base_url, workspace_path, session_id, read_timeout_ms) do
      {:ok, _} = ok ->
        ok

      :error when attempts_left > 0 ->
        Process.sleep(500)
        fetch_latest_completed_assistant_message_with_retry(
          base_url,
          workspace_path,
          session_id,
          read_timeout_ms,
          attempts_left - 1
        )

      _ ->
        :error
    end
  end

  defp fetch_latest_completed_assistant_message(base_url, workspace_path, session_id, read_timeout_ms) do
    url =
      base_url <>
        "/session/" <> URI.encode_www_form(session_id) <> "/message?directory=" <> URI.encode_www_form(workspace_path) <> "&limit=20"

    request = Finch.build(:get, url)

    case Finch.request(request, Symphony.Finch, receive_timeout: max(1_000, read_timeout_ms)) do
      {:ok, %Finch.Response{status: status, body: raw}} when status in 200..299 ->
        case Jason.decode(raw) do
          {:ok, list} when is_list(list) ->
            list
            |> Enum.filter(fn msg ->
              is_map(msg) and
                get_in(msg, ["info", "role"]) == "assistant" and
                not is_nil(get_in(msg, ["info", "time", "completed"]))
            end)
            |> Enum.max_by(
              fn msg -> to_int(get_in(msg, ["info", "time", "completed"])) end,
              fn -> nil end
            )
            |> case do
              nil -> :error
              msg -> {:ok, msg}
            end

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp abort_session(base_url, workspace_path, session_id, read_timeout_ms) do
    url =
      base_url <>
        "/session/" <> URI.encode_www_form(session_id) <> "/abort?directory=" <> URI.encode_www_form(workspace_path)

    request = Finch.build(:post, url, [{"content-type", "application/json"}], "{}")

    _ = Finch.request(request, Symphony.Finch, receive_timeout: max(1_000, read_timeout_ms))
    :ok
  end

  defp dispose_server(base_url, read_timeout_ms) do
    request = Finch.build(:post, base_url <> "/global/dispose", [{"content-type", "application/json"}], "{}")

    _ = Finch.request(request, Symphony.Finch, receive_timeout: max(1_000, read_timeout_ms))
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp emit_session_started(on_update, session_id) do
    on_update.(%{
      event: :session_started,
      thread_id: session_id,
      turn_id: nil,
      session_id: session_id
    })

    :ok
  end

  defp emit_response_parts(on_update, response, usage, session_id) do
    on_update.(%{
      type: :codex_update,
      payload: response,
      usage: usage,
      thread_id: session_id,
      turn_id: nil,
      session_id: session_id
    })

    response
    |> Map.get("parts", [])
    |> List.wrap()
    |> Enum.each(fn part ->
      if part["type"] == "text" and is_binary(part["text"]) and String.trim(part["text"]) != "" do
        on_update.(%{type: :codex_stdout, line: part["text"], usage: usage})
      end
    end)

    :ok
  end

  defp ensure_success_response(response, accepted_finishes \\ ["stop", "completed"]) do
    info = response["info"] || %{}
    finish = info["finish"]
    error = info["error"]

    cond do
      not is_nil(error) ->
        {:error, {:opencode_server_error, error}}

      is_binary(finish) and finish not in accepted_finishes ->
        {:error, {:opencode_server_finish, finish}}

      true ->
        :ok
    end
  end

  defp extract_usage(response) do
    tokens = get_in(response, ["info", "tokens"]) || %{}

    usage = %{
      input_tokens: to_int(tokens["input"]),
      output_tokens: to_int(tokens["output"]),
      total_tokens:
        to_int(
          tokens["total"] ||
            (to_int(tokens["input"]) + to_int(tokens["output"]))
        )
    }

    {:ok, usage}
  end

  defp create_session(base_url, workspace_path, issue, read_timeout_ms, deadline_ms) do
    payload =
      %{}
      |> maybe_put("title", session_title(issue))
      |> Map.put("permission", session_permissions())

    post_json(base_url, "/session", workspace_path, payload, read_timeout_ms, deadline_ms)
  end

  defp session_permissions do
    [
      %{"permission" => "bash", "pattern" => "*", "action" => "allow"},
      %{"permission" => "read", "pattern" => "*", "action" => "allow"},
      %{"permission" => "edit", "pattern" => "*", "action" => "allow"},
      %{"permission" => "write", "pattern" => "*", "action" => "allow"},
      %{"permission" => "list", "pattern" => "*", "action" => "allow"},
      %{"permission" => "glob", "pattern" => "*", "action" => "allow"},
      %{"permission" => "grep", "pattern" => "*", "action" => "allow"}
    ]
  end

  defp session_title(nil), do: "Symphony session"
  defp session_title(%{identifier: id, title: title}) when is_binary(id) and is_binary(title), do: "#{id} - #{title}"
  defp session_title(%{identifier: id}) when is_binary(id), do: id
  defp session_title(_), do: "Symphony session"

  defp extract_session_id(%{"id" => session_id}) when is_binary(session_id) and session_id != "" do
    {:ok, session_id}
  end

  defp extract_session_id(_), do: {:error, :opencode_server_session_missing_id}

  defp send_prompt_async(base_url, workspace_path, session_id, prompt, routing, config, read_timeout_ms, deadline_ms) do
    {provider_id, model_id} = model_components(routing[:model], routing[:provider], config.codex_model)

    payload =
      %{
        "parts" => [%{"type" => "text", "text" => prompt}],
        "agent" => resolve_agent(config.codex_command),
        "model" => %{"providerID" => provider_id, "modelID" => model_id}
      }
      |> maybe_put("variant", resolve_variant(routing[:effort]))

    path = "/session/#{URI.encode_www_form(session_id)}/prompt_async"
    post_json_no_content(base_url, path, workspace_path, payload, read_timeout_ms, deadline_ms)
  end

  defp post_json(base_url, path, workspace_path, payload, read_timeout_ms, deadline_ms, opts \\ []) do
    url = base_url <> path <> "?directory=" <> URI.encode_www_form(workspace_path)

    body =
      case Jason.encode(payload) do
        {:ok, encoded} -> encoded
        _ -> nil
      end

    if is_nil(body) do
      {:error, :json_encode_error}
    else
      request =
        Finch.build(:post, url, [{"content-type", "application/json"}], body)

      timeout_base =
        if Keyword.get(opts, :long_request, false) do
          max(30_000, read_timeout_ms * 20)
        else
          max(1_000, read_timeout_ms)
        end

      timeout = min(timeout_base, max(1_000, remaining_ms(deadline_ms)))

      case Finch.request(request, Symphony.Finch, receive_timeout: timeout) do
        {:ok, %Finch.Response{status: status, body: raw}} when status in 200..299 ->
          case Jason.decode(raw) do
            {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
            _ -> {:error, :opencode_server_malformed_json}
          end

        {:ok, %Finch.Response{status: status, body: raw}} ->
          {:error, {:opencode_server_http_error, status, raw}}

        {:error, reason} ->
          {:error, {:opencode_server_transport_error, reason}}
      end
    end
  end

  defp post_json_no_content(base_url, path, workspace_path, payload, read_timeout_ms, deadline_ms) do
    url = base_url <> path <> "?directory=" <> URI.encode_www_form(workspace_path)

    body =
      case Jason.encode(payload) do
        {:ok, encoded} -> encoded
        _ -> nil
      end

    if is_nil(body) do
      {:error, :json_encode_error}
    else
      request = Finch.build(:post, url, [{"content-type", "application/json"}], body)
      timeout = min(max(1_000, read_timeout_ms), max(1_000, remaining_ms(deadline_ms)))

      case Finch.request(request, Symphony.Finch, receive_timeout: timeout) do
        {:ok, %Finch.Response{status: status}} when status in [200, 202, 204] ->
          :ok

        {:ok, %Finch.Response{status: status, body: raw}} ->
          {:error, {:opencode_server_http_error, status, raw}}

        {:error, reason} ->
          {:error, {:opencode_server_transport_error, reason}}
      end
    end
  end

  defp wait_for_health(base_url, deadline_ms, read_timeout_ms) do
    if remaining_ms(deadline_ms) <= 0 do
      {:error, :turn_timeout}
    else
      case get_json(base_url <> "/global/health", read_timeout_ms, deadline_ms) do
        {:ok, %{"healthy" => true}} ->
          :ok

        {:ok, _} ->
          Process.sleep(100)
          wait_for_health(base_url, deadline_ms, read_timeout_ms)

        {:error, _reason} ->
          Process.sleep(100)
          wait_for_health(base_url, deadline_ms, read_timeout_ms)
      end
    end
  end

  defp get_json(url, read_timeout_ms, deadline_ms) do
    request = Finch.build(:get, url)
    timeout = min(max(1_000, read_timeout_ms), max(1_000, remaining_ms(deadline_ms)))

    case Finch.request(request, Symphony.Finch, receive_timeout: timeout) do
      {:ok, %Finch.Response{status: status, body: raw}} when status in 200..299 ->
        case Jason.decode(raw) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
          _ -> {:error, :opencode_server_malformed_json}
        end

      {:ok, %Finch.Response{status: status, body: raw}} ->
        {:error, {:opencode_server_http_error, status, raw}}

      {:error, reason} ->
        {:error, {:opencode_server_transport_error, reason}}
    end
  end

  defp remaining_ms(deadline_ms) do
    max(0, deadline_ms - System.monotonic_time(:millisecond))
  end

  defp model_components(routing_model, routing_provider, fallback_model) do
    model = normalize_model(routing_model || fallback_model)

    case String.split(model, "/", parts: 2) do
      [provider_id, model_id] when provider_id != "" and model_id != "" ->
        {provider_id, model_id}

      [model_id] ->
        {provider_id_for(routing_provider, model_id), model_id}

      _ ->
        {"zai-coding-plan", "glm-5"}
    end
  end

  defp provider_id_for(provider, model_id) do
    cond do
      to_string(provider) == "codex" -> "openai"
      String.starts_with?(String.downcase(model_id), "gpt-") -> "openai"
      true -> "zai-coding-plan"
    end
  end

  defp normalize_model(nil), do: "zai-coding-plan/glm-5"

  defp normalize_model(model) when is_binary(model) do
    normalized = String.trim(model)

    cond do
      normalized == "" -> "zai-coding-plan/glm-5"
      String.contains?(normalized, "/") -> normalized
      String.downcase(normalized) in ["glm-5", "glm5"] -> "zai-coding-plan/glm-5"
      String.downcase(normalized) in ["glm-4.7", "glm47"] -> "zai-coding-plan/glm-4.7"
      String.downcase(normalized) in ["codex-5-3", "gpt-5.3-codex"] -> "openai/gpt-5.3-codex"
      true -> normalized
    end
  end

  defp normalize_model(other), do: to_string(other)

  defp resolve_variant(nil), do: nil
  defp resolve_variant("xhigh"), do: "max"
  defp resolve_variant("high"), do: "high"
  defp resolve_variant("medium"), do: "medium"
  defp resolve_variant("low"), do: "low"
  defp resolve_variant(value) when is_binary(value), do: String.trim(value)
  defp resolve_variant(_), do: nil

  defp resolve_agent(command) when is_binary(command) do
    parts = String.split(command, ~r/\s+/, trim: true)

    case Enum.find_index(parts, &(&1 == "--agent")) do
      nil -> "general"
      idx -> Enum.at(parts, idx + 1) || "general"
    end
  end

  defp resolve_agent(_), do: "general"

  defp build_server_command(command, port) when is_binary(command) do
    lower = String.downcase(command)

    base =
      cond do
        String.contains?(lower, "opencode") and String.contains?(lower, "serve") -> command
        true -> "opencode serve"
      end

    base
    |> append_if_missing("--hostname", @default_host)
    |> append_if_missing("--port", Integer.to_string(port))
  end

  defp build_server_command(_, port), do: "opencode serve --hostname #{@default_host} --port #{port}"

  defp append_if_missing(command, flag, value) do
    if String.contains?(command, flag) do
      command
    else
      command <> " " <> flag <> " " <> value
    end
  end

  defp opencode_env(config, routing) do
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

  defp maybe_put_env(env, _key, nil), do: env

  defp maybe_put_env(env, key, value) when is_binary(value) do
    normalized = String.trim(value)
    if normalized == "", do: env, else: Map.put(env, key, normalized)
  end

  defp maybe_put_env(env, _key, _), do: env

  defp maybe_put(map, _key, nil), do: map

  defp maybe_put(map, key, value) when is_binary(value) do
    normalized = String.trim(value)
    if normalized == "", do: map, else: Map.put(map, key, normalized)
  end

  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp close_port(port) do
    if is_port(port) and Port.info(port) != nil do
      Port.close(port)
    end
  end

  defp pick_available_port do
    case :gen_tcp.listen(0, [:binary, {:packet, 0}, {:active, false}, {:reuseaddr, true}]) do
      {:ok, socket} ->
        chosen_port =
          case :inet.sockname(socket) do
            {:ok, {_addr, port}} when is_integer(port) and port > 0 -> port
            _ -> 4096
          end

        _ = :gen_tcp.close(socket)
        chosen_port

      _ ->
        4096
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
end
