defmodule Symphony.WorkspaceManager do
  @moduledoc "Per-issue workspace resolution and deterministic hooks."

  require Logger

  alias Symphony.Shell

  defstruct [:path, :workspace_key, :issue_identifier]

  def workspace_for_issue(identifier, workspace_root) do
    key = sanitize_identifier(identifier)

    %__MODULE__{
      workspace_key: key,
      issue_identifier: identifier,
      path: Path.join(workspace_root, key)
    }
  end

  def ensure_workspace(identifier, workspace_root, hooks, hook_timeout_ms) do
    workspace = workspace_for_issue(identifier, workspace_root)
    path = workspace.path

    bootstrap_needed? =
      with :ok <- validate_path(path) do
        workspace_bootstrap_needed?(path)
      else
        _ -> true
      end

    with :ok <- ensure_root_under_root(path, workspace_root),
         {:ok, created} <- ensure_directory(path),
         :ok <- cleanup_temp_artifacts(path),
         {:ok, bootstrap_metadata_tmp} <-
           prepare_for_bootstrap(path, created or bootstrap_needed?),
         :ok <-
           run_hook_if_strict(
             :after_create,
             hooks,
             path,
             hook_timeout_ms,
             created or bootstrap_needed?
           ),
         :ok <- restore_bootstrap_metadata(path, bootstrap_metadata_tmp) do
      {:ok, workspace, path}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def run_before_run_hook(hooks, path, timeout_ms) do
    run_named_hook(:before_run, hooks, path, timeout_ms, false)
  end

  def run_after_run_hook(hooks, path, timeout_ms) do
    run_named_hook(:after_run, hooks, path, timeout_ms, false)
  end

  def run_before_remove_hook(hooks, path, timeout_ms) do
    run_named_hook(:before_remove, hooks, path, timeout_ms, false)
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
      {:ok, %{type: :directory}} ->
        {:ok, false}

      {:ok, _} ->
        {:error, :path_not_directory}

      {:error, :enoent} ->
        File.mkdir_p(path)
        |> case do
          :ok -> {:ok, true}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp workspace_bootstrap_needed?(path) do
    not File.dir?(Path.join(path, ".git")) or not workspace_has_checked_out_files?(path)
  end

  defp prepare_for_bootstrap(path, true) do
    metadata_tmp =
      Path.join(
        System.tmp_dir!(),
        "symphony-bootstrap-#{System.unique_integer([:positive])}"
      )

    File.rm_rf(metadata_tmp)

    with :ok <- stash_bootstrap_metadata(path, metadata_tmp),
         :ok <- clear_workspace_entries(path) do
      {:ok, metadata_tmp}
    end
  end

  defp prepare_for_bootstrap(_path, false), do: {:ok, nil}

  defp restore_bootstrap_metadata(_path, nil), do: :ok

  defp restore_bootstrap_metadata(path, metadata_tmp) do
    if File.dir?(metadata_tmp) do
      target = Path.join(path, ".git/symphony")
      File.mkdir_p!(Path.dirname(target))

      case File.cp_r(metadata_tmp, target) do
        {:ok, _} ->
          File.rm_rf(metadata_tmp)
          :ok

        {:error, _, reason} ->
          {:error, reason}
      end
    else
      :ok
    end
  end

  defp stash_bootstrap_metadata(path, metadata_tmp) do
    source = Path.join(path, ".git/symphony")

    if File.dir?(source) do
      File.mkdir_p!(Path.dirname(metadata_tmp))

      case File.cp_r(source, metadata_tmp) do
        {:ok, _} -> :ok
        {:error, _, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp clear_workspace_entries(path) do
    case File.ls(path) do
      {:ok, entries} ->
        Enum.reduce_while(entries, :ok, fn entry, :ok ->
          case File.rm_rf(Path.join(path, entry)) do
            {:ok, _} -> {:cont, :ok}
            {:error, _, reason} -> {:halt, {:error, reason}}
          end
        end)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp return_error(reason), do: {:error, reason}

  defp workspace_has_checked_out_files?(path) do
    path
    |> File.ls!()
    |> Enum.reject(&internal_workspace_entry?/1)
    |> Enum.any?()
  rescue
    _ -> false
  end

  defp internal_workspace_entry?(".git"), do: true
  defp internal_workspace_entry?(".symphony"), do: true
  defp internal_workspace_entry?(".symphony-opencode"), do: true
  defp internal_workspace_entry?(".elixir_ls"), do: true
  defp internal_workspace_entry?("tmp"), do: true
  defp internal_workspace_entry?(_), do: false

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

      run_hook(script, path, timeout_ms, true, type)
    else
      :ok
    end
  end

  defp run_named_hook(type, hooks, path, timeout_ms, strict) do
    script =
      case type do
        :after_create -> hooks[:after_create]
        :before_run -> hooks[:before_run]
        :after_run -> hooks[:after_run]
        :before_remove -> hooks[:before_remove]
        _ -> nil
      end

    run_hook(script, path, timeout_ms, strict, type)
  end

  defp run_hook(script, path, timeout_ms, strict, type) do
    with :ok <- validate_path(path) do
      case Shell.run_script(script, path, timeout_ms) do
        {:ok, output} ->
          case output |> to_string() |> String.trim() do
            "" -> :ok
            trimmed -> Logger.info("#{type} hook ok: #{Shell.truncate(trimmed, 500)}")
          end

          :ok

        {:error, reason} ->
          Logger.warning("#{type} hook failed: #{inspect(reason)}")
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
