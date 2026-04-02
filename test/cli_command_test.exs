defmodule Symphony.CLICommandTest do
  use ExUnit.Case, async: true

  alias Symphony.CLICommand

  test "run halts for help and missing workflow" do
    parsed = %{help?: true, workflow_path: "./WORKFLOW.md"}
    assert CLICommand.run(parsed, %{}) == {:halt, 0, :help}

    parsed = %{help?: false, workflow_path: "/missing", project_slug: nil}

    assert CLICommand.run(parsed, %{
             file_exists?: fn _ -> false end
           }) == {:halt, 2, "workflow file not found: /missing"}
  end

  test "run halts when interactive defaults fail or project is already locked" do
    parsed = %{help?: false, workflow_path: "/wf", project_slug: "proj"}

    deps = %{
      file_exists?: fn _ -> true end,
      preflight_runtime_overrides: fn _ -> :ok end,
      ensure_prestart_services: fn -> %{started_finch_pid: nil} end,
      resolve_interactive_defaults: fn _, _ -> {:error, :no_projects_found} end
    }

    assert CLICommand.run(parsed, deps) ==
             {:halt, 2, "failed to resolve startup defaults: :no_projects_found"}

    deps =
      Map.merge(deps, %{
        resolve_interactive_defaults: fn _, _ -> {:ok, parsed} end,
        apply_runtime_overrides: fn _ -> :ok end,
        persist_runtime_context: fn _, _ -> :ok end,
        project_lock_path: fn "proj" -> "/tmp/proj.lock" end,
        acquire_project_lock: fn _ -> {:error, {:already_running, 123}} end
      })

    assert CLICommand.run(parsed, deps) ==
             {:halt, 1, "another Symphony instance is already running for project proj (pid 123)"}
  end

  test "run starts the app when no supervisor exists and releases lock on start failure" do
    parsed = %{help?: false, workflow_path: "/wf", project_slug: "proj"}
    {:ok, released} = Agent.start_link(fn -> [] end)
    {:ok, stopped} = Agent.start_link(fn -> [] end)

    deps = %{
      file_exists?: fn _ -> true end,
      preflight_runtime_overrides: fn _ -> :ok end,
      ensure_prestart_services: fn -> %{started_finch_pid: self()} end,
      resolve_interactive_defaults: fn _, _ -> {:ok, parsed} end,
      apply_runtime_overrides: fn _ -> :ok end,
      persist_runtime_context: fn _, _ -> :ok end,
      project_lock_path: fn _ -> "/tmp/proj.lock" end,
      acquire_project_lock: fn _ -> :ok end,
      whereis_supervisor: fn -> nil end,
      stop_prestart_services: fn prestart ->
        Agent.update(stopped, &[prestart | &1])
        :ok
      end,
      start_application: fn _ -> {:error, :boom} end,
      release_project_lock: fn path ->
        Agent.update(released, &[path | &1])
        :ok
      end
    }

    assert CLICommand.run(parsed, deps) == {:halt, 1, "failed to start: :boom"}
    assert Agent.get(stopped, & &1) == [%{started_finch_pid: self()}]
    assert Agent.get(released, & &1) == ["/tmp/proj.lock"]
  end

  test "run sleeps forever when app start succeeds or supervisor already exists" do
    parsed = %{help?: false, workflow_path: "/wf", project_slug: nil}

    base = %{
      file_exists?: fn _ -> true end,
      preflight_runtime_overrides: fn _ -> :ok end,
      ensure_prestart_services: fn -> %{started_finch_pid: nil} end,
      resolve_interactive_defaults: fn _, _ -> {:ok, parsed} end,
      apply_runtime_overrides: fn _ -> :ok end,
      persist_runtime_context: fn _, _ -> :ok end,
      project_lock_path: fn _ -> nil end,
      acquire_project_lock: fn _ -> :ok end,
      release_project_lock: fn _ -> :ok end,
      stop_prestart_services: fn _ -> :ok end
    }

    assert CLICommand.run(parsed, Map.merge(base, %{
             whereis_supervisor: fn -> nil end,
             start_application: fn _ -> {:ok, self()} end
           })) == {:sleep_forever, parsed}

    assert CLICommand.run(parsed, Map.merge(base, %{
             whereis_supervisor: fn -> self() end,
             start_application: fn _ -> flunk("should not start application") end
           })) == {:sleep_forever, parsed}
  end
end
