defmodule Symphony.WorkspaceSnapshotTest do
  use ExUnit.Case, async: true

  setup do
    workspace = Path.join(System.tmp_dir!(), "symphony-workspace-snapshot-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.join(workspace, ".git/symphony"))

    System.cmd("git", ["init", "-b", "main"], cd: workspace)
    System.cmd("git", ["config", "user.name", "Symphony Test"], cd: workspace)
    System.cmd("git", ["config", "user.email", "symphony@example.com"], cd: workspace)
    File.write!(Path.join(workspace, "README.md"), "hello\n")
    System.cmd("git", ["add", "README.md"], cd: workspace)
    System.cmd("git", ["commit", "-m", "init"], cd: workspace)

    on_exit(fn ->
      File.rm_rf!(workspace)
    end)

    %{workspace: workspace}
  end

  test "reports no progress when the workspace is unchanged", %{workspace: workspace} do
    snapshot = Symphony.WorkspaceSnapshot.capture(workspace)

    refute Symphony.WorkspaceSnapshot.progress_made?(workspace, snapshot)
  end

  test "detects git status changes", %{workspace: workspace} do
    snapshot = Symphony.WorkspaceSnapshot.capture(workspace)
    File.write!(Path.join(workspace, "README.md"), "updated\n")

    assert Symphony.WorkspaceSnapshot.progress_made?(workspace, snapshot)
  end

  test "detects new demo plan artifacts", %{workspace: workspace} do
    snapshot = Symphony.WorkspaceSnapshot.capture(workspace)
    File.write!(Path.join(workspace, ".git/symphony/demo-plan.json"), "{}")

    assert Symphony.WorkspaceSnapshot.progress_made?(workspace, snapshot)
  end
end
