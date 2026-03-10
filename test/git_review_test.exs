defmodule Symphony.GitReviewTest do
  use ExUnit.Case, async: false

  setup do
    root =
      Path.join(System.tmp_dir!(), "symphony-git-review-#{System.unique_integer([:positive])}")

    origin = Path.join(root, "origin.git")
    workspace = Path.join(root, "workspace")
    bin_dir = Path.join(root, "bin")
    gh_log = Path.join(root, "gh.log")
    gh_path = Path.join(bin_dir, "gh")
    File.mkdir_p!(bin_dir)
    File.mkdir_p!(root)

    File.write!(
      gh_path,
      """
      #!/bin/bash
      printf '%s\n' "$*" >> "#{gh_log}"
      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$3" = "--repo" ] && [ "$4" = "test/repo" ] && [ "$5" = "--head" ]; then
        printf '%s' '[]'
        exit 0
      fi
      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$3" = "--repo" ] && [ "$4" = "test/repo" ] && [ "$5" = "--state" ]; then
        printf '%s' '[{"number":42,"url":"https://github.com/test/repo/pull/42","headRefName":"symphony/sbo-15"}]'
        exit 0
      fi
      if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
        printf '%s' 'https://github.com/test/repo/pull/42'
        exit 0
      fi
      if [ "$1" = "pr" ] && [ "$2" = "edit" ]; then
        exit 0
      fi
      if [ "$1" = "pr" ] && [ "$2" = "merge" ] && [ "$5" = "--auto" ]; then
        printf '%s' 'auto merge enabled'
        exit 0
      fi
      if [ "$1" = "pr" ] && [ "$2" = "merge" ]; then
        printf '%s' 'merged'
        exit 0
      fi
      if [ "$1" = "pr" ] && [ "$2" = "view" ] && [ "$7" = "mergedAt" ]; then
        printf '%s' '{"mergedAt":"2026-03-10T00:00:00Z"}'
        exit 0
      fi
      if [ "$1" = "pr" ] && [ "$2" = "view" ] && [ "$7" = "mergeStateStatus" ]; then
        printf '%s' '{"mergeStateStatus":"CLEAN"}'
        exit 0
      fi
      exit 0
      """
    )

    File.chmod!(gh_path, 0o755)
    original_path = System.get_env("PATH") || ""
    System.put_env("PATH", bin_dir <> ":" <> original_path)

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
    run_git(["remote", "set-url", "--push", "origin", origin], workspace)

    on_exit(fn ->
      System.put_env("PATH", original_path)
      File.rm_rf(root)
    end)

    %{root: root, origin: origin, workspace: workspace, gh_log: gh_log}
  end

  test "prepare_workspace reuses current issue branch with dirty changes", %{workspace: workspace} do
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

  test "open_review_pr creates a PR and records merge state", %{
    workspace: workspace,
    gh_log: gh_log
  } do
    issue = %Symphony.Issue{id: "1", identifier: "SBO-15", title: "Test issue"}

    config = %Symphony.Config{
      review_pr_enabled: true,
      review_pr_draft: false,
      review_pr_base_branch: "main",
      review_pr_auto_merge: true
    }

    assert {:ok, branch_info} = Symphony.GitReview.prepare_workspace(issue, workspace, config)
    File.write!(Path.join(workspace, "CHANGELOG.md"), "new change\n")

    assert {:ok, review} =
             Symphony.GitReview.open_review_pr(issue, workspace, config, branch_info)

    assert review.pr_number == 42
    assert review.pr_url == "https://github.com/test/repo/pull/42"
    assert review.auto_merge_enabled == true

    assert {:ok, log} = File.read(gh_log)
    assert log =~ "pr create"
    assert log =~ "pr merge 42 --repo test/repo --auto --squash"
  end

  test "merge_review_pr merges an existing PR", %{workspace: workspace, gh_log: gh_log} do
    review = %{repo_slug: "test/repo", pr_number: 42}

    assert {:ok, merged} = Symphony.GitReview.merge_review_pr(workspace, review)
    assert merged.pr_merged == true
    assert merged.auto_merge_enabled == false

    assert {:ok, log} = File.read(gh_log)
    assert log =~ "pr view 42 --repo test/repo --json mergeStateStatus"
    assert log =~ "pr merge 42 --repo test/repo --squash --delete-branch"
  end

  test "find_open_review_pr returns the first matching PR" do
    assert {:ok, review} = Symphony.GitReview.find_open_review_pr("test/repo", "SBO-15")
    assert review.pr_number == 42
    assert review.branch == "symphony/sbo-15"
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
