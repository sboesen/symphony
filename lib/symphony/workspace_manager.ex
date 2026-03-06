defmodule Symphony.WorkspaceManager do
  @moduledoc "Per-issue workspace resolution and deterministic hooks." 

  require Logger

  alias Symphony.Shell

  defstruct [:path, :workspace_key, :issue_identifier]

  def workspace_for_issue(identifier, workspace_root) do
    key = sanitize_identifier(identifier)
    %__MODULE__{workspace_key: key, issue_identifier: identifier, path: Path.join(workspace_root, key)}
  end

  def ensure_workspace(identifier, workspace_root, hooks, hook_timeout_ms) do
    workspace = workspace_for_issue(identifier, workspace_root)
    path = workspace.path

    with :ok <- ensure_root_under_root(path, workspace_root),
         {:ok, created} <- ensure_directory(path),
         :ok <- cleanup_temp_artifacts(path),
         :ok <- run_hook_if_strict(:after_create, hooks, path, hook_timeout_ms, created) do
      {:ok, workspace, path}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def run_before_run_hook(hooks, path, timeout_ms) do
    run_hook(:before_run, hooks, path, timeout_ms, false)
  end

  def run_after_run_hook(hooks, path, timeout_ms) do
    run_hook(:after_run, hooks, path, timeout_ms, false)
  end

  def run_before_remove_hook(hooks, path, timeout_ms) do
    run_hook(:before_remove, hooks, path, timeout_ms, false)
  end

  def cleanup_workspace(path, workspace_root, hooks, timeout_ms) do
    with :ok <- validate_path(path),
         :ok <- run_before_remove_hook(hooks, path, timeout_ms),
         :ok <- ensure_root_under_root(path, workspace_root),
         :ok <- rm_rf(path) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("workspace cleanup warning: #{inspect(reason)}")
        :ok
    end
  end

  def sanitize_identifier(identifier) do
    identifier
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
  end

  defp ensure_directory(path) do
    case File.stat(path) do
      {:ok, %{type: :directory}} -> {:ok, false}
      {:ok, _} -> {:error, :path_not_directory}
      {:error, :enoent} ->
        File.mkdir_p(path)
        |> case do
          :ok -> {:ok, true}
          {:error, reason} -> {:error, reason}
        end
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_hook_if_strict(type, hooks, path, timeout_ms, strict) do
    if strict do
      script =
        case type do
          :after_create -> hooks[:after_create]
          :before_run -> hooks[:before_run]
          :after_run -> hooks[:after_run]
          :before_remove -> hooks[:before_remove]
          _ -> nil
        end

      run_hook(script, path, timeout_ms, true)
    else
      :ok
    end
  end

  defp run_hook(type, hooks, path, timeout_ms, strict) do
    script =
      case type do
        :after_create -> hooks[:after_create]
        :before_run -> hooks[:before_run]
        :after_run -> hooks[:after_run]
        :before_remove -> hooks[:before_remove]
        _ -> nil
      end

    run_hook(script, path, timeout_ms, strict)
  end

  defp run_hook(script, path, timeout_ms, strict) do
    with :ok <- validate_path(path) do
      case Shell.run_script(script, path, timeout_ms) do
        {:ok, output} ->
          Logger.info("hook ok: #{Shell.truncate(output, 500)}")
          :ok

        {:error, reason} ->
          Logger.warning("hook failed: #{inspect(reason)}")
          if strict, do: {:error, reason}, else: :ok
      end
    end
  end

  defp ensure_root_under_root(path, root) do
    expanded_path = Path.expand(path)
    expanded_root = Path.expand(root)
    relative = Path.relative_to(expanded_path, expanded_root)

    if relative != expanded_path and not String.starts_with?(relative, "..") do
      :ok
    else
      {:error, :workspace_outside_root}
    end
  end

  defp cleanup_temp_artifacts(path) do
    _ = rm_rf(Path.join(path, "tmp"))
    _ = rm_rf(Path.join(path, ".elixir_ls"))
    :ok
  end

  defp rm_rf(path) do
    case File.rm_rf(path) do
      {:ok, _} -> :ok
      {:error, _, _} -> {:error, :remove_failed}
    end
  end

  defp validate_path(path) when is_binary(path) and path != "", do: :ok
  defp validate_path(_), do: {:error, :workspace_path_invalid}
end
