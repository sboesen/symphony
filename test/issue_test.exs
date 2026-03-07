defmodule Symphony.IssueTest do
  use ExUnit.Case, async: true

  test "from_payload normalizes comments, labels, blockers, and timestamps" do
    payload = %{
      "id" => "issue-1",
      "identifier" => "SBO-99",
      "title" => "Example issue",
      "description" => "desc",
      "priority" => "2",
      "state" => %{"name" => "In Review"},
      "branchName" => "feature/sbo-99",
      "url" => "https://linear.app/sboesen/issue/SBO-99/example-issue",
      "labels" => %{"nodes" => [%{"name" => "Feature"}, %{"name" => "Feature"}, %{"name" => "UX"}]},
      "blockedBy" => %{
        "nodes" => [
          %{"id" => "block-1", "identifier" => "SBO-10", "state" => %{"name" => "Todo"}}
        ]
      },
      "comments" => %{
        "nodes" => [
          %{
            "id" => "c-old",
            "body" => "First note",
            "createdAt" => "2026-03-07T00:00:00Z",
            "updatedAt" => "2026-03-07T00:00:00Z",
            "user" => %{"name" => "Stefan"}
          },
          %{
            "id" => "c-new",
            "body" => "Second note",
            "createdAt" => "2026-03-07T01:00:00Z",
            "updatedAt" => "2026-03-07T01:00:00Z",
            "user" => %{"name" => "Symphony"}
          }
        ]
      },
      "createdAt" => "2026-03-07T00:00:00Z",
      "updatedAt" => "2026-03-07T01:00:00Z"
    }

    issue = Symphony.Issue.from_payload(payload)

    assert issue.identifier == "SBO-99"
    assert issue.priority == 2
    assert issue.state == "in review"
    assert issue.branch_name == "feature/sbo-99"
    assert issue.labels == ["feature", "ux"]
    assert issue.blocked_by == [%{id: "block-1", identifier: "SBO-10", state: "Todo"}]
    assert [%{id: "c-new"}, %{id: "c-old"}] = issue.comments
    assert issue.comments_text =~ "Stefan: First note"
    assert issue.comments_text =~ "Symphony: Second note"
    assert issue.created_at == DateTime.from_naive!(~N[2026-03-07 00:00:00], "Etc/UTC")
    assert issue.updated_at == DateTime.from_naive!(~N[2026-03-07 01:00:00], "Etc/UTC")
    assert Symphony.Issue.blocked_by_has_non_terminal?(issue, ["done", "cancelled"]) == true
  end

  test "from_payload tolerates missing nested nodes without raising" do
    issue =
      Symphony.Issue.from_payload(%{
        "id" => "issue-2",
        "identifier" => "SBO-100",
        "title" => "Sparse issue",
        "comments" => %{"nodes" => nil},
        "labels" => %{"nodes" => nil},
        "blockedBy" => %{"nodes" => nil}
      })

    assert issue.comments == []
    assert issue.labels == []
    assert issue.blocked_by == []
    assert issue.comments_text == ""
  end
end
