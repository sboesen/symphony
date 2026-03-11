defmodule Symphony.CLIRuntimeTest do
  use ExUnit.Case, async: false

  alias Symphony.CLIRuntime

  test "persist_runtime_context writes workflow, project, and repo fields" do
    runtime_path =
      Path.join(System.tmp_dir!(), "symphony-runtime-#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(runtime_path) end)

    parsed = %{project_slug: "proj-1", repo_url: "git@github.com:acme/repo.git"}

    assert :ok = CLIRuntime.persist_runtime_context(parsed, "/tmp/workflow.md", runtime_path)
    assert {:ok, body} = File.read(runtime_path)
    assert {:ok, decoded} = Jason.decode(body)
    assert decoded["workflow_path"] == "/tmp/workflow.md"
    assert decoded["project_slug"] == "proj-1"
    assert decoded["repo_url"] == "git@github.com:acme/repo.git"
  end

  test "persist_runtime_context is a no-op when runtime path is blank" do
    assert :ok = CLIRuntime.persist_runtime_context(%{project_slug: nil, repo_url: nil}, "/tmp/workflow.md", "   ")
  end

  test "project_lock_path returns nil for missing slugs and a temp path otherwise" do
    assert CLIRuntime.project_lock_path(nil) == nil
    assert CLIRuntime.project_lock_path("") == nil
    assert CLIRuntime.project_lock_path("proj-1") =~ "symphony-project-proj-1.lock"
  end

  test "acquire_project_lock writes current pid when file is missing or stale" do
    lock_path =
      Path.join(System.tmp_dir!(), "symphony-project-#{System.unique_integer([:positive])}.lock")

    on_exit(fn -> File.rm(lock_path) end)

    assert :ok = CLIRuntime.acquire_project_lock(lock_path, "1234", fn _ -> false end)
    assert File.read!(lock_path) == "1234"

    File.write!(lock_path, "9999")
    assert :ok = CLIRuntime.acquire_project_lock(lock_path, "4321", fn _ -> false end)
    assert File.read!(lock_path) == "4321"
  end

  test "acquire_project_lock rejects live owners" do
    lock_path =
      Path.join(System.tmp_dir!(), "symphony-project-#{System.unique_integer([:positive])}.lock")

    File.write!(lock_path, "9999")

    on_exit(fn -> File.rm(lock_path) end)

    assert {:error, {:already_running, 9999}} =
             CLIRuntime.acquire_project_lock(lock_path, "1234", fn pid -> pid == 9999 end)
  end

  test "release_project_lock only removes matching pid files" do
    lock_path =
      Path.join(System.tmp_dir!(), "symphony-project-#{System.unique_integer([:positive])}.lock")

    File.write!(lock_path, "2222")
    assert :ok = CLIRuntime.release_project_lock(lock_path, 1111)
    assert File.exists?(lock_path)

    assert :ok = CLIRuntime.release_project_lock(lock_path, 2222)
    refute File.exists?(lock_path)
  end

  test "force_release_project_lock always removes the file" do
    lock_path =
      Path.join(System.tmp_dir!(), "symphony-project-#{System.unique_integer([:positive])}.lock")

    File.write!(lock_path, "2222")
    assert :ok = CLIRuntime.force_release_project_lock(lock_path)
    refute File.exists?(lock_path)
    assert :ok = CLIRuntime.force_release_project_lock(nil)
  end

  test "pid helpers return usable values" do
    assert is_binary(CLIRuntime.os_pid())
    assert is_integer(CLIRuntime.os_pid_int())
    assert CLIRuntime.pid_alive?(-1) == false
  end
end
