defmodule Symphony.LinearClientTest do
  use ExUnit.Case, async: false

  alias Plug.Conn
  alias Symphony.Tracker.LinearClient

  setup do
    parent = self()
    ref = make_ref()
    Application.put_env(:symphony, :linear_client_test_pid, parent)

    {:ok, _pid} =
      Plug.Cowboy.http(__MODULE__.Router, [], ip: {127, 0, 0, 1}, port: 0, ref: ref)

    port = :ranch.get_port(ref)

    on_exit(fn ->
      Application.delete_env(:symphony, :linear_client_test_pid)
      Plug.Cowboy.shutdown(ref)
    end)

    config = %Symphony.Config{
      tracker_kind: "linear",
      tracker_endpoint: "http://127.0.0.1:#{port}",
      tracker_api_key: "test-linear-key",
      read_timeout_ms: 1_000
    }

    %{config: config}
  end

  test "upsert_workpad reuses an existing Symphony-managed comment when local metadata is missing",
       %{
         config: config
       } do
    issue = %Symphony.Issue{id: "issue-1", identifier: "TEST-1", title: "Issue", comments: []}
    body = Symphony.PlanContract.render_planning_placeholder("Recovered")

    assert {:ok, %{action: :updated, comment_id: "comment-existing", body: ^body}} =
             LinearClient.upsert_workpad(config, issue, body)

    assert_receive {:graphql_request, "query", %{"id" => "issue-1"}}

    assert_receive {:graphql_request, "mutation",
                    %{"id" => "comment-existing", "input" => %{"body" => ^body}}}

    refute_receive {:graphql_request, "mutation", %{"input" => %{"issueId" => "issue-1"}}}
  end

  defmodule Router do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/" do
      {:ok, raw, conn} = Conn.read_body(conn)
      {:ok, payload} = Jason.decode(raw)
      test_pid = Application.fetch_env!(:symphony, :linear_client_test_pid)

      send(
        test_pid,
        {:graphql_request, operation_type(payload["query"]), payload["variables"] || %{}}
      )

      query = payload["query"] || ""

      response =
        cond do
          String.contains?(query, "comments(first: 50)") ->
            %{
              "data" => %{
                "issue" => %{
                  "id" => "issue-1",
                  "comments" => %{
                    "nodes" => [
                      %{
                        "id" => "comment-existing",
                        "body" => Symphony.PlanContract.render_planning_placeholder("Recovered"),
                        "createdAt" => "2026-03-09T12:00:00Z",
                        "updatedAt" => "2026-03-09T12:00:00Z",
                        "user" => %{"name" => "Symphony"}
                      }
                    ]
                  }
                }
              }
            }

          String.contains?(query, "commentUpdate") ->
            %{
              "data" => %{
                "commentUpdate" => %{
                  "success" => true,
                  "comment" => %{"id" => "comment-existing"}
                }
              }
            }

          String.contains?(query, "commentCreate") ->
            %{
              "data" => %{
                "commentCreate" => %{
                  "success" => true,
                  "comment" => %{"id" => "comment-created"}
                }
              }
            }
        end

      Conn.send_resp(conn, 200, Jason.encode!(response))
    end

    defp operation_type(query) when is_binary(query) do
      if String.trim_leading(query) |> String.starts_with?("mutation"),
        do: "mutation",
        else: "query"
    end
  end
end
