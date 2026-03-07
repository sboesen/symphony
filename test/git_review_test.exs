defmodule Symphony.GitReviewTest do
  use ExUnit.Case, async: false

  test "prepare_workspace reuses current issue branch with dirty changes" do
    root = Path.join(System.tmp_dir!(), "symphony-git-review-#{System.unique_integer([:positive])}")
    origin = Path.join(root, "origin.git")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    run_git(["init", "--bare", origin], root)
    run_git(["clone", origin, workspace], root)
    run_git(["config", "user.name", "Test"], workspace)
    run_git(["config", "user.email", "test@example.com"], workspace)
    File.write!(Path.join(workspace, "README.md"), "hello\n")
    run_git(["add", "README.md"], workspace)
    run_git(["commit", "-m", "init"], workspace)
    run_git(["branch", "-M", "main"], workspace)
    run_git(["push", "-u", "origin", "main"], workspace)
    run_git(["remote", "set-url", "origin", "https://github.com/test/repo.git"], workspace)

    issue = %Symphony.Issue{
      id: "1",
      identifier: "SBO-15",
      title: "Test issue",
      branch_name: "stefanboesen/sbo-15-test-issue"
    }

    config = %Symphony.Config{
      review_pr_enabled: true,
      review_pr_draft: false,
      review_pr_base_branch: "main"
    }

    assert :ok = run_git(["checkout", "-B", issue.branch_name, "main"], workspace)
    File.write!(Path.join(workspace, "README.md"), "changed\n")

    assert {:ok, branch_info} = Symphony.GitReview.prepare_workspace(issue, workspace, config)
    assert branch_info.branch == issue.branch_name
    assert branch_info.base_branch == "main"
    assert branch_info.repo_slug == "test/repo"
    assert current_branch(workspace) == issue.branch_name
    assert File.read!(Path.join(workspace, "README.md")) == "changed\n"
  end

  defp run_git(args, cwd) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{out}")
    end
  end
  defp current_branch(cwd) do
    {out, 0} = System.cmd("git", ["branch", "--show-current"], cd: cwd, stderr_to_stdout: true)
    String.trim(out)
  end
end
