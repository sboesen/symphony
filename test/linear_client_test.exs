defmodule Symphony.LinearClientTest do
  use ExUnit.Case, async: false

  alias Plug.Conn
  alias Symphony.Tracker.LinearClient

  setup do
    parent = self()
    ref = make_ref()
    {:ok, state_pid} = Agent.start_link(fn -> initial_state() end)
    Application.put_env(:symphony, :linear_client_test_pid, parent)
    Application.put_env(:symphony, :linear_client_test_state, state_pid)

    {:ok, _pid} =
      Plug.Cowboy.http(__MODULE__.Router, [], ip: {127, 0, 0, 1}, port: 0, ref: ref)

    port = :ranch.get_port(ref)
    endpoint = "http://127.0.0.1:#{port}"
    Application.put_env(:symphony, :linear_client_test_endpoint, endpoint)

    on_exit(fn ->
      Application.delete_env(:symphony, :linear_client_test_pid)
      Application.delete_env(:symphony, :linear_client_test_state)
      Application.delete_env(:symphony, :linear_client_test_endpoint)
      Plug.Cowboy.shutdown(ref)

      if Process.alive?(state_pid) do
        Agent.stop(state_pid)
      end
    end)

    config = %Symphony.Config{
      tracker_kind: "linear",
      tracker_endpoint: endpoint,
      tracker_api_key: "test-linear-key",
      tracker_project_slug: "project-1",
      tracker_active_states: ["Todo", "In Progress"],
      read_timeout_ms: 1_000,
      recording_publish_to_tracker: true,
      recording_publish_comment: true
    }

    %{config: config}
  end

  test "lists and updates projects", %{config: config} do
    assert {:ok, [%{slug_id: "project-1"} = project]} = LinearClient.list_projects(config)
    assert {:ok, ^project} = LinearClient.fetch_project_by_slug(config, "project-1")

    assert {:ok, updated} =
             LinearClient.save_project_repo(config, project, "https://github.com/acme/repo")

    assert updated.description =~ "https://github.com/acme/repo"
  end

  test "lists and mutates webhooks", %{config: config} do
    assert {:ok, hooks} = LinearClient.list_webhooks(config)
    assert Enum.any?(hooks, &(&1.id == "hook-1"))

    assert {:ok, %{id: "hook-3"}} =
             LinearClient.create_webhook(config, %{label: "New hook", url: "https://x.test/hook"})

    assert {:ok, %{id: "hook-3"}} = LinearClient.delete_webhook(config, "hook-3")
  end

  test "fetches issues by identifier and state filters", %{config: config} do
    assert {:ok, %Symphony.Issue{identifier: "TEST-1"}} =
             LinearClient.fetch_issue_by_identifier(config, "TEST-1")

    assert {:ok, issues} = LinearClient.fetch_candidates(config)
    assert Enum.map(issues, & &1.identifier) == ["TEST-1", "TEST-2"]

    assert {:ok, [%Symphony.Issue{id: "issue-1"}]} =
             LinearClient.fetch_states_by_ids(config, ["issue-1"])
  end

  test "transitions tracker states", %{config: config} do
    assert :ok = LinearClient.mark_in_review(config, "issue-1")

    assert_receive {:graphql_request, "mutation",
                    %{"id" => "issue-1", "stateId" => "state-review"}}

    assert :ok = LinearClient.mark_done(config, "issue-1")
    assert_receive {:graphql_request, "mutation", %{"id" => "issue-1", "stateId" => "state-done"}}
  end

  test "publishes clarification and review handoff comments", %{config: config} do
    issue = %Symphony.Issue{id: "issue-1", identifier: "TEST-1", title: "Issue", comments: []}

    assert {:ok, %{action: :created, comment_id: "comment-3"}} =
             LinearClient.publish_clarification(config, issue, "Need more detail")

    review_artifact = %{
      pr_url: "https://github.com/acme/repo/pull/1",
      pr_title: "TEST-1 review",
      branch: "feature/test-1",
      base_branch: "main",
      commit_sha: "abc123",
      auto_merge_enabled: false,
      pr_merged: false
    }

    assert {:ok,
            %{linear_attachment_id: "attachment-existing", linear_comment_id: "comment-review"}} =
             LinearClient.publish_review_handoff(config, issue, review_artifact)
  end

  test "publishes recording artifacts and upserts managed comments", %{config: config} do
    issue = %Symphony.Issue{id: "issue-1", identifier: "TEST-1", title: "Issue", comments: []}

    workspace =
      Path.join(
        System.tmp_dir!(),
        "linear-client-artifacts-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    screenshot = Path.join(workspace, "shot.png")
    File.write!(screenshot, "png-data")

    on_exit(fn -> File.rm_rf!(workspace) end)

    artifact = %{kind: "demo_artifact", screenshot_path: screenshot}

    assert {:ok, [published]} = LinearClient.publish_artifacts(config, issue, [artifact])
    assert published.published == true
    assert published.linear_asset_url == "http://127.0.0.1/uploaded/shot.png"
    assert published.linear_comment_id == "comment-recording"
  end

  test "upsert_workpad reuses an existing Symphony-managed comment when local metadata is missing",
       %{config: config} do
    issue = %Symphony.Issue{id: "issue-1", identifier: "TEST-1", title: "Issue", comments: []}
    body = Symphony.PlanContract.render_planning_placeholder("Recovered")

    assert {:ok, %{action: :updated, comment_id: "comment-existing", body: ^body}} =
             LinearClient.upsert_workpad(config, issue, body)
  end

  defp initial_state do
    %{
      projects: [
        %{
          "id" => "project-1",
          "name" => "Project 1",
          "slugId" => "project-1",
          "description" => "Initial description",
          "state" => "planned",
          "teams" => %{"nodes" => [%{"id" => "team-1", "key" => "TEST", "name" => "Team"}]}
        }
      ],
      webhooks: [
        %{
          "id" => "hook-1",
          "label" => "Existing hook",
          "url" => "https://x.test/linear/webhook/project-1",
          "enabled" => true,
          "team" => %{"id" => "team-1", "key" => "TEST", "name" => "Team"}
        }
      ],
      issues: %{
        "issue-1" => issue_payload("issue-1", "TEST-1", "In Progress"),
        "issue-2" => issue_payload("issue-2", "TEST-2", "Todo"),
        "issue-3" => issue_payload("issue-3", "TEST-3", "Done")
      },
      comments: %{
        "issue-1" => [
          comment(
            "comment-existing",
            Symphony.PlanContract.render_planning_placeholder("Recovered")
          ),
          comment(
            "comment-review",
            "Review handoff PR: [PR](https://github.com/acme/repo/pull/1)\n\n<!-- symphony-review -->"
          ),
          comment(
            "comment-recording",
            "http://127.0.0.1/uploaded/shot.png\n\n<!-- symphony-recording -->"
          )
        ]
      },
      attachments: %{
        "issue-1" => [
          %{
            "id" => "attachment-existing",
            "title" => "TEST-1 review",
            "subtitle" => "Symphony review PR",
            "url" => "https://github.com/acme/repo/pull/1"
          }
        ]
      },
      next_comment_id: 3,
      next_hook_id: 3
    }
  end

  defp issue_payload(id, identifier, state_name) do
    %{
      "id" => id,
      "identifier" => identifier,
      "title" => "#{identifier} title",
      "description" => "Issue description",
      "comments" => %{"nodes" => []},
      "priority" => 1,
      "state" => %{
        "name" => state_name,
        "id" => state_id_for(state_name),
        "type" => state_type_for(state_name)
      },
      "team" => %{
        "states" => %{
          "nodes" => [
            %{"id" => "state-backlog", "name" => "Backlog", "type" => "backlog"},
            %{"id" => "state-todo", "name" => "Todo", "type" => "unstarted"},
            %{"id" => "state-started", "name" => "In Progress", "type" => "started"},
            %{"id" => "state-review", "name" => "In Review", "type" => "started"},
            %{"id" => "state-done", "name" => "Done", "type" => "completed"}
          ]
        }
      },
      "branchName" => "feature/#{String.downcase(identifier)}",
      "url" => "https://linear.app/issue/#{identifier}",
      "labels" => %{"nodes" => [%{"name" => "bug"}]},
      "createdAt" => "2026-03-09T12:00:00Z",
      "updatedAt" => "2026-03-09T12:00:00Z"
    }
  end

  defp comment(id, body) do
    %{
      "id" => id,
      "body" => body,
      "createdAt" => "2026-03-09T12:00:00Z",
      "updatedAt" => "2026-03-09T12:00:00Z",
      "user" => %{"name" => "Symphony"}
    }
  end

  defp state_id_for("In Progress"), do: "state-started"
  defp state_id_for("Todo"), do: "state-todo"
  defp state_id_for("Done"), do: "state-done"
  defp state_id_for("In Review"), do: "state-review"
  defp state_id_for(_), do: "state-backlog"

  defp state_type_for("Done"), do: "completed"
  defp state_type_for("Todo"), do: "unstarted"
  defp state_type_for(_), do: "started"

  defmodule Router do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/" do
      {:ok, raw, conn} = Conn.read_body(conn)
      {:ok, payload} = Jason.decode(raw)
      test_pid = Application.fetch_env!(:symphony, :linear_client_test_pid)
      state_pid = Application.fetch_env!(:symphony, :linear_client_test_state)
      query = payload["query"] || ""
      variables = payload["variables"] || %{}

      send(test_pid, {:graphql_request, operation_type(query), variables})

      response = build_response(query, variables, state_pid)
      Conn.send_resp(conn, 200, Jason.encode!(response))
    end

    put "/upload" do
      Conn.send_resp(conn, 200, "")
    end

    defp build_response(query, variables, state_pid) do
      cond do
        String.contains?(query, "projects(first: 50)") ->
          %{"data" => %{"projects" => %{"nodes" => Agent.get(state_pid, & &1.projects)}}}

        String.contains?(query, "projectUpdate") ->
          project =
            Agent.get_and_update(state_pid, fn state ->
              updated =
                Enum.map(state.projects, fn project ->
                  if project["id"] == variables["id"] do
                    Map.put(project, "description", get_in(variables, ["input", "description"]))
                  else
                    project
                  end
                end)

              project = Enum.find(updated, &(&1["id"] == variables["id"]))
              {project, %{state | projects: updated}}
            end)

          %{"data" => %{"projectUpdate" => %{"success" => true, "project" => project}}}

        String.contains?(query, "webhooks(first: 100)") ->
          %{"data" => %{"webhooks" => %{"nodes" => Agent.get(state_pid, & &1.webhooks)}}}

        String.contains?(query, "webhookCreate") ->
          webhook =
            Agent.get_and_update(state_pid, fn state ->
              id = "hook-#{state.next_hook_id}"

              webhook =
                Map.merge(
                  %{
                    "id" => id,
                    "enabled" => true,
                    "team" => %{"id" => "team-1", "key" => "TEST", "name" => "Team"}
                  },
                  stringify_keys(variables["input"] || %{})
                )

              {webhook,
               %{
                 state
                 | webhooks: state.webhooks ++ [webhook],
                   next_hook_id: state.next_hook_id + 1
               }}
            end)

          %{"data" => %{"webhookCreate" => %{"success" => true, "webhook" => webhook}}}

        String.contains?(query, "webhookDelete") ->
          Agent.update(state_pid, fn state ->
            %{state | webhooks: Enum.reject(state.webhooks, &(&1["id"] == variables["id"]))}
          end)

          %{"data" => %{"webhookDelete" => %{"success" => true}}}

        String.contains?(query, "issues(filter: { team:") ->
          issue =
            Agent.get(state_pid, fn state ->
              state.issues
              |> Map.values()
              |> Enum.find(
                &(&1["identifier"] == "#{variables["teamKey"]}-#{trunc(variables["number"])}")
              )
            end)

          %{"data" => %{"issues" => %{"nodes" => List.wrap(issue)}}}

        String.contains?(query, "issues(filter: {project:") ->
          issues = Agent.get(state_pid, fn state -> Map.values(state.issues) end)

          %{
            "data" => %{
              "issues" => %{
                "nodes" => issues,
                "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
              }
            }
          }

        String.contains?(query, "comments(first: 50)") ->
          comments =
            Agent.get(state_pid, fn state -> Map.get(state.comments, variables["id"], []) end)

          %{
            "data" => %{
              "issue" => %{"id" => variables["id"], "comments" => %{"nodes" => comments}}
            }
          }

        String.contains?(query, "attachments(first: 50)") ->
          attachments =
            Agent.get(state_pid, fn state -> Map.get(state.attachments, variables["id"], []) end)

          %{"data" => %{"issue" => %{"attachments" => %{"nodes" => attachments}}}}

        String.contains?(query, "state { id name type }") ->
          issue = Agent.get(state_pid, fn state -> Map.fetch!(state.issues, variables["id"]) end)

          %{
            "data" => %{
              "issue" => %{
                "id" => issue["id"],
                "state" => issue["state"],
                "team" => issue["team"]
              }
            }
          }

        String.contains?(query, "issueUpdate") ->
          send(
            Application.fetch_env!(:symphony, :linear_client_test_pid),
            {:graphql_request, "mutation", variables}
          )

          Agent.update(state_pid, fn state ->
            update_issue_state(state, variables["id"], variables["stateId"])
          end)

          %{"data" => %{"issueUpdate" => %{"success" => true}}}

        String.contains?(query, "fileUpload") ->
          filename = variables["filename"]

          %{
            "data" => %{
              "fileUpload" => %{
                "success" => true,
                "uploadFile" => %{
                  "uploadUrl" =>
                    Application.fetch_env!(:symphony, :linear_client_test_endpoint) <> "/upload",
                  "assetUrl" => "http://127.0.0.1/uploaded/#{filename}",
                  "headers" => []
                }
              }
            }
          }

        String.contains?(query, "attachmentCreate") ->
          %{
            "data" => %{
              "attachmentCreate" => %{
                "success" => true,
                "attachment" => %{"id" => "attachment-new"}
              }
            }
          }

        String.contains?(query, "commentCreate") ->
          comment =
            Agent.get_and_update(state_pid, fn state ->
              id = "comment-#{state.next_comment_id}"
              issue_id = get_in(variables, ["input", "issueId"])
              body = get_in(variables, ["input", "body"])
              comment = comment(id, body)
              comments = Map.update(state.comments, issue_id, [comment], &(&1 ++ [comment]))
              {comment, %{state | comments: comments, next_comment_id: state.next_comment_id + 1}}
            end)

          %{
            "data" => %{
              "commentCreate" => %{"success" => true, "comment" => %{"id" => comment["id"]}}
            }
          }

        String.contains?(query, "commentUpdate") ->
          Agent.update(state_pid, fn state ->
            comments =
              Map.new(state.comments, fn {issue_id, comments} ->
                updated =
                  Enum.map(comments, fn comment ->
                    if comment["id"] == variables["id"] do
                      Map.put(comment, "body", get_in(variables, ["input", "body"]))
                    else
                      comment
                    end
                  end)

                {issue_id, updated}
              end)

            %{state | comments: comments}
          end)

          %{
            "data" => %{
              "commentUpdate" => %{"success" => true, "comment" => %{"id" => variables["id"]}}
            }
          }

        String.contains?(query, "issue(id: $id)") ->
          issue =
            Agent.get(state_pid, fn state ->
              issue = Map.fetch!(state.issues, variables["id"])

              Map.put(issue, "comments", %{
                "nodes" => Map.get(state.comments, variables["id"], [])
              })
            end)

          %{"data" => %{"issue" => issue}}
      end
    end

    defp update_issue_state(state, issue_id, state_id) do
      {name, type} =
        case state_id do
          "state-review" -> {"In Review", "started"}
          "state-done" -> {"Done", "completed"}
          "state-todo" -> {"Todo", "unstarted"}
          "state-backlog" -> {"Backlog", "backlog"}
          _ -> {"In Progress", "started"}
        end

      issues =
        Map.update!(state.issues, issue_id, fn issue ->
          Map.put(issue, "state", %{"id" => state_id, "name" => name, "type" => type})
        end)

      %{state | issues: issues}
    end

    defp comment(id, body) do
      %{
        "id" => id,
        "body" => body,
        "createdAt" => "2026-03-09T12:00:00Z",
        "updatedAt" => "2026-03-09T12:00:00Z",
        "user" => %{"name" => "Symphony"}
      }
    end

    defp stringify_keys(map) when is_map(map) do
      Map.new(map, fn {key, value} -> {to_string(key), value} end)
    end

    defp operation_type(query) when is_binary(query) do
      if String.trim_leading(query) |> String.starts_with?("mutation"),
        do: "mutation",
        else: "query"
    end
  end
end
