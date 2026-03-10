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

  test "from_payload filters Symphony-managed workpad comments from recent comments context" do
    issue =
      Symphony.Issue.from_payload(%{
        "id" => "issue-3",
        "identifier" => "SBO-101",
        "title" => "Prompt hygiene",
        "comments" => %{
          "nodes" => [
            %{
              "id" => "c-human",
              "body" => "Please keep this scoped to /posts.",
              "createdAt" => "2026-03-07T00:00:00Z",
              "updatedAt" => "2026-03-07T00:00:00Z",
              "user" => %{"name" => "Stefan"}
            },
            %{
              "id" => "c-workpad",
              "body" => "## Plan\n\n- [ ] Do the thing\n\n_Maintained by Symphony._",
              "createdAt" => "2026-03-07T01:00:00Z",
              "updatedAt" => "2026-03-07T01:00:00Z",
              "user" => %{"name" => "Symphony"}
            }
          ]
        }
      })

    assert [%{id: "c-human"}] = issue.comments
    assert issue.comments_text =~ "Stefan: Please keep this scoped to /posts."
    refute issue.comments_text =~ "_Maintained by Symphony._"
    refute issue.comments_text =~ "## Plan"
  end

  test "from_payload filters Symphony review and recording comments from prompt context" do
    issue =
      Symphony.Issue.from_payload(%{
        "id" => "issue-4",
        "identifier" => "SBO-102",
        "title" => "Prompt hygiene follow-up",
        "comments" => %{
          "nodes" => [
            %{
              "id" => "c-human",
              "body" => "Please retry this only after removing the GitHub link.",
              "createdAt" => "2026-03-07T00:00:00Z",
              "updatedAt" => "2026-03-07T00:00:00Z",
              "user" => %{"name" => "Stefan"}
            },
            %{
              "id" => "c-review",
              "body" => "Review handoff PR: [Example](https://github.com/example/repo/pull/1)\n\n_Symphony review handoff._",
              "createdAt" => "2026-03-07T01:00:00Z",
              "updatedAt" => "2026-03-07T01:00:00Z",
              "user" => %{"name" => "Symphony"}
            },
            %{
              "id" => "c-recording",
              "body" => "https://uploads.linear.app/example\n\n_Symphony recording artifact._",
              "createdAt" => "2026-03-07T02:00:00Z",
              "updatedAt" => "2026-03-07T02:00:00Z",
              "user" => %{"name" => "Symphony"}
            }
          ]
        }
      })

    assert [%{id: "c-human"}] = issue.comments
    assert issue.comments_text =~ "Stefan: Please retry this only after removing the GitHub link."
    refute issue.comments_text =~ "_Symphony review handoff._"
    refute issue.comments_text =~ "_Symphony recording artifact._"
  end

  test "from_payload filters new Symphony marker comments from prompt context" do
    issue =
      Symphony.Issue.from_payload(%{
        "id" => "issue-5",
        "identifier" => "SBO-103",
        "title" => "Marker hygiene",
        "comments" => %{
          "nodes" => [
            %{
              "id" => "c-human",
              "body" => "Please only remove the Help link, not the About link.",
              "createdAt" => "2026-03-07T00:00:00Z",
              "updatedAt" => "2026-03-07T00:00:00Z",
              "user" => %{"name" => "Stefan"}
            },
            %{
              "id" => "c-plan",
              "body" => "## Plan\n\n- [ ] Thing\n\n[Symphony:plan]\n_Maintained by Symphony._",
              "createdAt" => "2026-03-07T01:00:00Z",
              "updatedAt" => "2026-03-07T01:00:00Z",
              "user" => %{"name" => "Symphony"}
            },
            %{
              "id" => "c-review",
              "body" => "Review handoff PR: [Example](https://github.com/example/repo/pull/1)\n\n<!-- symphony-review -->",
              "createdAt" => "2026-03-07T02:00:00Z",
              "updatedAt" => "2026-03-07T02:00:00Z",
              "user" => %{"name" => "Symphony"}
            },
            %{
              "id" => "c-recording",
              "body" => "![demo](https://uploads.linear.app/example/image)\n\n<!-- symphony-recording -->",
              "createdAt" => "2026-03-07T03:00:00Z",
              "updatedAt" => "2026-03-07T03:00:00Z",
              "user" => %{"name" => "Symphony"}
            }
          ]
        }
      })

    assert [%{id: "c-human"}] = issue.comments
    assert issue.comments_text =~ "Stefan: Please only remove the Help link, not the About link."
    refute issue.comments_text =~ "[Symphony:plan]"
    refute issue.comments_text =~ "<!-- symphony-review -->"
    refute issue.comments_text =~ "<!-- symphony-recording -->"
  end

  test "from_payload filters hidden Symphony clarification comments from prompt context" do
    issue =
      Symphony.Issue.from_payload(%{
        "id" => "issue-6",
        "identifier" => "SBO-104",
        "title" => "Clarification hygiene",
        "comments" => %{
          "nodes" => [
            %{
              "id" => "c-human",
              "body" => "Please keep the settings gear aligned with the nav.",
              "createdAt" => "2026-03-07T00:00:00Z",
              "updatedAt" => "2026-03-07T00:00:00Z",
              "user" => %{"name" => "Stefan"}
            },
            %{
              "id" => "c-clarification",
              "body" => "Clarification needed before continuing:\n\nNeed repo access\n\n<!-- symphony-clarification -->",
              "createdAt" => "2026-03-07T01:00:00Z",
              "updatedAt" => "2026-03-07T01:00:00Z",
              "user" => %{"name" => "Symphony"}
            }
          ]
        }
      })

    assert [%{id: "c-human"}] = issue.comments
    assert issue.comments_text =~ "Stefan: Please keep the settings gear aligned with the nav."
    refute issue.comments_text =~ "Need repo access"
    refute issue.comments_text =~ "<!-- symphony-clarification -->"
  end
end
