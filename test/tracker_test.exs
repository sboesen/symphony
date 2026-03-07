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

  defp write_mock!(content) do
    path = Path.join(System.tmp_dir!(), "tracker-test-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(content))
    path
  end
end
