defmodule Symphony.CLICommand do
  @moduledoc false

  alias Symphony.CLIRuntime

  def run(parsed, deps) do
    workflow_path = parsed.workflow_path

    cond do
      parsed.help? ->
        {:halt, 0, :help}

      not deps.file_exists?.(workflow_path) ->
        {:halt, 2, "workflow file not found: #{workflow_path}"}

      true ->
        deps.preflight_runtime_overrides.(parsed)
        prestart = deps.ensure_prestart_services.()

        case deps.resolve_interactive_defaults.(parsed, workflow_path) do
          {:ok, resolved} ->
            deps.apply_runtime_overrides.(resolved)
            deps.persist_runtime_context.(resolved, workflow_path)
            lock_file = deps.project_lock_path.(resolved.project_slug)

            case deps.acquire_project_lock.(lock_file) do
              :ok ->
                continue_after_lock(resolved, workflow_path, lock_file, prestart, deps)

              {:error, {:already_running, pid}} ->
                {:halt, 1,
                 "another Symphony instance is already running for project #{resolved.project_slug} (pid #{pid})"}
            end

          {:error, reason} ->
            {:halt, 2, "failed to resolve startup defaults: #{inspect(reason)}"}
        end
    end
  end

  defp continue_after_lock(parsed, workflow_path, lock_file, prestart, deps) do
    case deps.whereis_supervisor.() do
      nil ->
        deps.stop_prestart_services.(prestart)

        case deps.start_application.(workflow_path) do
          {:ok, _pid} ->
            {:sleep_forever, parsed}

          {:error, reason} ->
            deps.release_project_lock.(lock_file)
            {:halt, 1, "failed to start: #{inspect(reason)}"}
        end

      _pid ->
        {:sleep_forever, parsed}
    end
  end

  def deps do
    %{
      file_exists?: &File.exists?/1,
      preflight_runtime_overrides: &Symphony.CLI.preflight_runtime_overrides/1,
      ensure_prestart_services: &Symphony.CLI.ensure_prestart_services/0,
      resolve_interactive_defaults: &Symphony.CLI.resolve_interactive_defaults/2,
      apply_runtime_overrides: &Symphony.CLI.apply_runtime_overrides/1,
      persist_runtime_context: &CLIRuntime.persist_runtime_context/2,
      project_lock_path: &CLIRuntime.project_lock_path/1,
      acquire_project_lock: &CLIRuntime.acquire_project_lock/1,
      release_project_lock: &CLIRuntime.release_project_lock/1,
      whereis_supervisor: fn -> Process.whereis(Symphony.Supervisor) end,
      stop_prestart_services: &Symphony.CLI.stop_prestart_services/1,
      start_application: fn workflow_path -> Symphony.Application.start(nil, workflow_path: workflow_path) end
    }
  end
end
