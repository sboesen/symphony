defmodule Symphony.MockTrackerTest do
  use ExUnit.Case, async: true

  test "fetch_issue_by_identifier returns normalized issue with comments" do
    path = Path.join(System.tmp_dir!(), "symphony-mock-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)

    File.write!(
      path,
      Jason.encode!(%{
        issues: [
          %{
            id: "1",
            identifier: "SBO-1",
            title: "Test",
            state: "Todo",
            comments: %{
              nodes: [
                %{
                  id: "c1",
                  body: "hello",
                  createdAt: "2026-03-07T00:00:00Z",
                  updatedAt: "2026-03-07T00:00:00Z",
                  user: %{name: "Stefan"}
                }
              ]
            }
          }
        ]
      })
    )

    config = %Symphony.Config{tracker_kind: "mock", tracker_mock_file: path}

    assert {:ok, issue} = Symphony.Tracker.fetch_issue_by_identifier(config, "SBO-1")
    assert issue.identifier == "SBO-1"
    assert issue.comments_text =~ "Stefan: hello"
  end
end
