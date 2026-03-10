defmodule Symphony.WorkspaceManagerTest do
  use ExUnit.Case, async: true

  alias Symphony.WorkspaceManager

  test "ensure_workspace reruns after_create when existing workspace lacks git repo" do
    root =
      Path.join(System.tmp_dir!(), "workspace-manager-test-#{System.unique_integer([:positive])}")

    identifier = "SBO-BOOTSTRAP-1"
    path = Path.join(root, identifier)
    File.mkdir_p!(path)

    marker = Path.join(path, "bootstrapped.txt")

    hooks = %{
      after_create: """
      echo ok > bootstrapped.txt
      mkdir -p .git
      """
    }

    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, _workspace, ^path} =
             WorkspaceManager.ensure_workspace(identifier, root, hooks, 5_000)

    assert File.exists?(marker)
    assert File.dir?(Path.join(path, ".git"))
  end

  test "ensure_workspace reruns after_create when workspace has only internal metadata" do
    root =
      Path.join(System.tmp_dir!(), "workspace-manager-test-#{System.unique_integer([:positive])}")

    identifier = "SBO-BOOTSTRAP-2"
    path = Path.join(root, identifier)
    File.mkdir_p!(Path.join(path, ".git/symphony"))
    File.mkdir_p!(Path.join(path, ".symphony-opencode"))

    marker = Path.join(path, "bootstrapped.txt")

    hooks = %{
      after_create: """
      echo ok > bootstrapped.txt
      mkdir -p .git
      """
    }

    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, _workspace, ^path} =
             WorkspaceManager.ensure_workspace(identifier, root, hooks, 5_000)

    assert File.exists?(marker)
  end

  test "ensure_workspace clears stale checkout files before bootstrap recovery" do
    root =
      Path.join(System.tmp_dir!(), "workspace-manager-test-#{System.unique_integer([:positive])}")

    identifier = "SBO-BOOTSTRAP-3"
    path = Path.join(root, identifier)
    File.mkdir_p!(path)
    File.write!(Path.join(path, "README.md"), "stale checkout")

    hooks = %{
      after_create: """
      test ! -e README.md
      echo ok > bootstrapped.txt
      mkdir -p .git
      """
    }

    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, _workspace, ^path} =
             WorkspaceManager.ensure_workspace(identifier, root, hooks, 5_000)

    assert File.exists?(Path.join(path, "bootstrapped.txt"))
    refute File.exists?(Path.join(path, "README.md"))
  end
end
