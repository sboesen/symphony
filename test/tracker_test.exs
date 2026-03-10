defmodule Symphony.TrackerTest do
  use ExUnit.Case, async: true

  test "fetch_candidates filters mock issues by active state" do
    path =
      write_mock!(%{
        issues: [
          %{id: "1", identifier: "SBO-1", title: "Todo issue", state: "Todo"},
          %{id: "2", identifier: "SBO-2", title: "Done issue", state: "Done"}
        ]
      })

    on_exit(fn -> File.rm(path) end)

    config = %Symphony.Config{
      tracker_kind: "mock",
      tracker_mock_file: path,
      tracker_active_states: ["Todo", "In Progress"]
    }

    assert {:ok, [%Symphony.Issue{identifier: "SBO-1"}]} = Symphony.Tracker.fetch_candidates(config)
  end

  test "fetch_states_by_ids accepts integer ids in mock tracker" do
    path =
      write_mock!([
        %{id: "1", identifier: "SBO-1", title: "Issue 1", state: "Todo"},
        %{id: "2", identifier: "SBO-2", title: "Issue 2", state: "Todo"}
      ])

    on_exit(fn -> File.rm(path) end)

    config = %Symphony.Config{tracker_kind: "mock", tracker_mock_file: path}

    assert {:ok, [%Symphony.Issue{identifier: "SBO-2"}]} =
             Symphony.Tracker.fetch_states_by_ids(config, [2])
  end

  test "mock tracker returns malformed error for invalid JSON shape" do
    path = Path.join(System.tmp_dir!(), "tracker-test-#{System.unique_integer([:positive])}.json")
    File.write!(path, "{")
    on_exit(fn -> File.rm(path) end)

    config = %Symphony.Config{
      tracker_kind: "mock",
      tracker_mock_file: path,
      tracker_active_states: ["Todo"]
    }

    assert {:error, :mock_file_malformed} = Symphony.Tracker.fetch_candidates(config)
  end

  test "mock tracker publish helpers echo artifacts without external calls" do
    config = %Symphony.Config{tracker_kind: "mock"}
    issue = %Symphony.Issue{id: "1", identifier: "SBO-1", title: "Issue"}
    artifacts = [%{kind: "recording", path: "/tmp/demo.mp4"}]
    review = %{kind: "pull_request", url: "https://github.com/example/repo/pull/1"}

    assert {:ok, ^artifacts} = Symphony.Tracker.publish_artifacts(config, issue, artifacts)
    assert {:ok, ^review} = Symphony.Tracker.publish_review_handoff(config, issue, review)
  end

  test "mock tracker accepts workpad upserts" do
    config = %Symphony.Config{tracker_kind: "mock"}
    issue = %Symphony.Issue{id: "1", identifier: "SBO-1", title: "Issue"}
    body = "## Plan\n\n- [ ] First step\n\n[Symphony:plan]\n_Maintained by Symphony._"

    assert {:ok, %{comment_id: "mock-workpad", body: ^body}} =
             Symphony.Tracker.upsert_workpad(config, issue, body)
  end

  test "mock tracker keeps the preferred workpad comment id shape stable" do
    config = %Symphony.Config{tracker_kind: "mock"}
    issue = %Symphony.Issue{id: "1", identifier: "SBO-1", title: "Issue"}
    body = "## Plan\n\n- [x] First step\n\n[Symphony:plan]\n_Maintained by Symphony._"

    assert {:ok, %{comment_id: "mock-workpad", body: ^body}} =
             Symphony.Tracker.upsert_workpad(config, issue, body, "existing-comment-id")
  end

  test "mock tracker supports webhook lifecycle helpers" do
    config = %Symphony.Config{tracker_kind: "mock"}

    assert {:ok, []} = Symphony.Tracker.list_webhooks(config)

    assert {:ok, %{id: "mock-linear-webhook", label: "Symphony local webhook"}} =
             Symphony.Tracker.create_webhook(config, %{label: "Symphony local webhook"})

    assert {:ok, %{id: "mock-linear-webhook"}} =
             Symphony.Tracker.delete_webhook(config, "mock-linear-webhook")
  end

  test "mock tracker supports project and issue lookup helpers" do
    path =
      write_mock!([
        %{id: "1", identifier: "SBO-1", title: "Issue 1", state: "Todo"},
        %{id: "2", identifier: "SBO-2", title: "Issue 2", state: "Done"}
      ])

    on_exit(fn -> File.rm(path) end)

    config = %Symphony.Config{
      tracker_kind: "mock",
      tracker_mock_file: path,
      tracker_terminal_states: ["Done"]
    }

    assert {:ok, [%{slug_id: "mock-project"}]} = Symphony.Tracker.list_projects(config)
    assert {:ok, %{slug_id: "proj-1"}} = Symphony.Tracker.fetch_project_by_slug(config, "proj-1")

    assert {:ok, %{repo_url: "git@github.com:acme/repo.git"}} =
             Symphony.Tracker.save_project_repo(
               config,
               %{id: "mock-project", slug_id: "proj-1"},
               "git@github.com:acme/repo.git"
             )

    assert {:ok, %Symphony.Issue{identifier: "SBO-1"}} =
             Symphony.Tracker.fetch_issue_by_identifier(config, "SBO-1")

    assert {:ok, [%Symphony.Issue{identifier: "SBO-2"}]} =
             Symphony.Tracker.fetch_terminal_issues(config, "Done")
  end

  test "mock tracker supports state transitions and clarification publishing" do
    config = %Symphony.Config{tracker_kind: "mock"}
    issue = %Symphony.Issue{id: "1", identifier: "SBO-1", title: "Issue"}

    assert :ok = Symphony.Tracker.mark_started(config, issue.id)
    assert :ok = Symphony.Tracker.mark_todo(config, issue.id)
    assert :ok = Symphony.Tracker.mark_backlog(config, issue.id)
    assert :ok = Symphony.Tracker.mark_in_review(config, issue.id)
    assert :ok = Symphony.Tracker.mark_done(config, issue.id)
    assert :ok = Symphony.Tracker.mark_completed(config, issue.id)

    assert {:ok, %{comment_id: "mock-clarification", body: "Need API key"}} =
             Symphony.Tracker.publish_clarification(config, issue, "Need API key", "comment-1")
  end

  test "unsupported tracker kind returns uniform errors" do
    config = %Symphony.Config{tracker_kind: "unknown"}
    issue = %Symphony.Issue{id: "1", identifier: "SBO-1", title: "Issue"}

    assert {:error, :unsupported_tracker} = Symphony.Tracker.fetch_candidates(config)
    assert {:error, :unsupported_tracker} = Symphony.Tracker.list_projects(config)
    assert {:error, :unsupported_tracker} = Symphony.Tracker.fetch_project_by_slug(config, "proj")
    assert {:error, :unsupported_tracker} = Symphony.Tracker.save_project_repo(config, %{}, "repo")
    assert {:error, :unsupported_tracker} = Symphony.Tracker.list_webhooks(config)
    assert {:error, :unsupported_tracker} = Symphony.Tracker.create_webhook(config, %{})
    assert {:error, :unsupported_tracker} = Symphony.Tracker.delete_webhook(config, "hook")
    assert {:error, :unsupported_tracker} = Symphony.Tracker.fetch_states_by_ids(config, [1])
    assert {:error, :unsupported_tracker} = Symphony.Tracker.fetch_issue_by_identifier(config, "SBO-1")
    assert {:error, :unsupported_tracker} = Symphony.Tracker.fetch_terminal_issues(config, ["Done"])
    assert {:error, :unsupported_tracker} = Symphony.Tracker.mark_started(config, "1")
    assert {:error, :unsupported_tracker} = Symphony.Tracker.mark_todo(config, "1")
    assert {:error, :unsupported_tracker} = Symphony.Tracker.mark_backlog(config, "1")
    assert {:error, :unsupported_tracker} = Symphony.Tracker.mark_in_review(config, "1")
    assert {:error, :unsupported_tracker} = Symphony.Tracker.mark_done(config, "1")
    assert {:error, :unsupported_tracker} = Symphony.Tracker.mark_completed(config, "1")
    assert {:error, :unsupported_tracker} = Symphony.Tracker.publish_clarification(config, issue, "body")
    assert {:error, :unsupported_tracker} = Symphony.Tracker.publish_artifacts(config, issue, [%{}])
    assert {:error, :unsupported_tracker} = Symphony.Tracker.publish_review_handoff(config, issue, %{})
    assert {:error, :unsupported_tracker} = Symphony.Tracker.upsert_workpad(config, issue, "body")
  end

  defp write_mock!(content) do
    path = Path.join(System.tmp_dir!(), "tracker-test-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(content))
    path
  end
end
