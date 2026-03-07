defmodule Symphony.Runner do
  @moduledoc "Dispatches turns to explicit execution backends (Codex app-server or OpenCode)."

  alias Symphony.{CodexAppServer, OpenCodeRunner, OpenCodeServerRunner}

  @supported_backends ["codex_app_server", "opencode", "opencode_server"]

  def run_turn(workspace_path, config, issue, attempt, prompt, routing, on_update)
      when is_function(on_update, 1) do
    profile = provider_profile(config, routing)
    backend = resolve_backend(profile, config.codex_command)
    effective_config = apply_command_override(config, profile, backend)

    case run_with_backend(
           backend,
           workspace_path,
           effective_config,
           issue,
           attempt,
           prompt,
           routing,
           on_update
         ) do
      {:error, reason} ->
        case fallback_route(config, routing, backend, reason) do
          nil ->
            {:error, reason}

          %{routing: fallback_routing, backend: fallback_backend} ->
            fallback_profile = provider_profile(config, fallback_routing)
            fallback_config = apply_command_override(config, fallback_profile, fallback_backend)

            on_update.(%{
              type: :routing,
              routing:
                fallback_routing
                |> Map.put(:reason, fallback_reason(backend, reason, fallback_routing))
                |> Map.put(:fallback_from_provider, routing[:provider])
                |> Map.put(:fallback_from_model, routing[:model])
                |> Map.put(:fallback_from_backend, backend)
            })

            run_with_backend(
              fallback_backend,
              workspace_path,
              fallback_config,
              issue,
              attempt,
              prompt,
              fallback_routing,
              on_update
            )
        end

      other ->
        other
    end
  end

  def supported_backends, do: @supported_backends

  defp provider_profile(config, routing) do
    provider = to_string(routing[:provider] || config.codex_router_default_provider || "zai")
    Map.get(config.codex_profiles || %{}, provider, %{name: provider})
  end

  defp resolve_backend(profile, default_command) do
    case profile[:backend] do
      backend when backend in @supported_backends ->
        backend

      _ ->
        command = profile[:command] || default_command

        cond do
          opencode_server_command?(command) -> "opencode_server"
          opencode_command?(command) -> "opencode"
          profile[:auth_mode] == "app_server" -> "codex_app_server"
          true -> "opencode"
        end
    end
  end

  defp run_with_backend("codex_app_server", workspace_path, config, issue, attempt, prompt, routing, on_update) do
    CodexAppServer.run_turn(workspace_path, config, issue, attempt, prompt, routing, on_update)
  end

  defp run_with_backend("opencode", workspace_path, config, issue, attempt, prompt, routing, on_update) do
    OpenCodeRunner.run_turn(workspace_path, config, issue, attempt, prompt, routing, on_update)
  end

  defp run_with_backend("opencode_server", workspace_path, config, issue, attempt, prompt, routing, on_update) do
    OpenCodeServerRunner.run_turn(workspace_path, config, issue, attempt, prompt, routing, on_update)
  end

  defp run_with_backend(other, _workspace_path, _config, _issue, _attempt, _prompt, _routing, _on_update) do
    {:error, {:unsupported_backend, other}}
  end

  defp apply_command_override(config, profile, backend) do
    command =
      case profile[:command] do
        value when is_binary(value) ->
          trimmed = String.trim(value)
          if trimmed == "", do: config.codex_command, else: trimmed

        _ -> config.codex_command
      end

    normalized_command =
      case backend do
        "opencode" ->
          if opencode_server_command?(command), do: "opencode", else: command

        "opencode_server" ->
          if opencode_command?(command) and not opencode_server_command?(command),
            do: command <> " serve",
            else: command

        _ ->
          command
      end

    %{config | codex_command: normalized_command}
  end

  defp fallback_route(config, routing, "codex_app_server", reason) do
    if codex_unsupported_account_model?(reason) do
      provider = config.codex_router_default_provider || "zai"
      profile = Map.get(config.codex_profiles || %{}, provider, %{})

      fallback_routing =
        routing
        |> Map.put(:provider, provider)
        |> Map.put(:model, profile[:model] || config.codex_router_model || config.codex_model || "GLM-5")
        |> Map.put(:model_provider, profile[:model_provider] || config.codex_model_provider)
        |> Map.put(:auth_mode, profile[:auth_mode])
        |> Map.put(:effort, config.codex_reasoning_effort)

      %{routing: fallback_routing, backend: resolve_backend(profile, config.codex_command)}
    else
      nil
    end
  end

  defp fallback_route(config, routing, "opencode_server", reason) do
    if opencode_server_unstable?(reason) do
      profile =
        provider_profile(config, routing)
        |> Map.put(:backend, "opencode")

      %{routing: routing, backend: resolve_backend(profile, "opencode")}
    else
      nil
    end
  end

  defp fallback_route(config, routing, "opencode", reason) do
    if opencode_cli_unstable?(reason) do
      profile =
        provider_profile(config, routing)
        |> Map.put(:backend, "opencode_server")

      %{routing: routing, backend: resolve_backend(profile, "opencode serve")}
    else
      nil
    end
  end

  defp fallback_route(_config, _routing, _backend, _reason), do: nil

  defp fallback_reason("codex_app_server", reason, _fallback_routing) do
    if codex_unsupported_account_model?(reason) do
      "fallback_from_unsupported_codex_account"
    else
      "fallback_from_codex_app_server"
    end
  end

  defp fallback_reason("opencode_server", _reason, _fallback_routing),
    do: "fallback_from_opencode_server"

  defp fallback_reason("opencode", _reason, _fallback_routing),
    do: "fallback_from_opencode_cli"

  defp fallback_reason(_backend, _reason, _fallback_routing), do: "fallback"

  defp codex_unsupported_account_model?(reason) do
    reason
    |> inspect()
    |> String.downcase()
    |> String.contains?("not supported when using codex with a chatgpt account")
  end

  defp opencode_server_unstable?(reason) do
    rendered = inspect(reason)

    rendered =~ "opencode_server_session_error" or
      rendered =~ "opencode_server_transport_error" or
      rendered =~ "opencode_server_http_error" or
      rendered =~ "turn_timeout" or
      rendered =~ "recording_setup_failed"
  end

  defp opencode_cli_unstable?(reason) do
    rendered = inspect(reason)

    rendered =~ "stall_timeout" or
      rendered =~ "turn_timeout" or
      rendered =~ "opencode_exit_status"
  end

  defp opencode_command?(nil), do: false

  defp opencode_command?(command) when is_binary(command) do
    command
    |> String.split(~r/\s+/, trim: true)
    |> List.first()
    |> case do
      nil -> false
      token -> Path.basename(token) == "opencode"
    end
  end

  defp opencode_server_command?(command) when is_binary(command) do
    lower = String.downcase(command)
    opencode_command?(command) and String.contains?(lower, " serve")
  end

  defp opencode_server_command?(_), do: false
end
