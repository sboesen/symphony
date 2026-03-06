defmodule Symphony.Runner do
  @moduledoc "Dispatches turns to explicit execution backends (Codex app-server or OpenCode)."

  alias Symphony.{CodexAppServer, OpenCodeRunner, OpenCodeServerRunner}

  @supported_backends ["codex_app_server", "opencode", "opencode_server"]

  def run_turn(workspace_path, config, issue, attempt, prompt, routing, on_update)
      when is_function(on_update, 1) do
    profile = provider_profile(config, routing)
    backend = resolve_backend(profile, config.codex_command)
    effective_config = apply_command_override(config, profile)

    case backend do
      "codex_app_server" ->
        CodexAppServer.run_turn(workspace_path, effective_config, issue, attempt, prompt, routing, on_update)

      "opencode" ->
        OpenCodeRunner.run_turn(workspace_path, effective_config, issue, attempt, prompt, routing, on_update)

      "opencode_server" ->
        OpenCodeServerRunner.run_turn(
          workspace_path,
          effective_config,
          issue,
          attempt,
          prompt,
          routing,
          on_update
        )

      other ->
        {:error, {:unsupported_backend, other}}
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

  defp apply_command_override(config, profile) do
    case profile[:command] do
      command when is_binary(command) ->
        normalized = String.trim(command)
        if normalized == "", do: config, else: %{config | codex_command: normalized}

      _ ->
        config
    end
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
