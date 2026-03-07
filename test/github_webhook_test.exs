defmodule Symphony.GitHubWebhookTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  test "rejects invalid signatures" do
    payload = %{"action" => "ping"}
    body = Jason.encode!(payload)

    conn =
      conn(:post, "/api/v1/github/webhook", body)
      |> Plug.Conn.assign(:raw_body, body)
      |> put_req_header("x-github-event", "ping")
      |> put_req_header("x-hub-signature-256", "sha256=bad")

    assert {:error, :invalid_github_signature} = Symphony.GitHubWebhook.handle(conn, payload)
  end

  test "rejects invalid session ids" do
    payload = %{"action" => "ping"}
    body = Jason.encode!(payload)
    current = Symphony.GitHubWebhookManager.current()
    refute is_nil(current)
    refute is_nil(current.session_id)

    conn =
      conn(:post, "/api/v1/github/webhook/session-other", body)
      |> Plug.Conn.assign(:raw_body, body)
      |> put_req_header("x-github-event", "ping")
      |> put_req_header("x-hub-signature-256", signature(body))

    assert {:error, :invalid_webhook_session} =
             Symphony.GitHubWebhook.handle(conn, payload, "session-other")
  end

  test "accepts supported signature for unsupported event" do
    payload = %{"zen" => "keep it logically awesome"}
    body = Jason.encode!(payload)

    conn =
      conn(:post, "/api/v1/github/webhook", body)
      |> Plug.Conn.assign(:raw_body, body)
      |> put_req_header("x-github-event", "ping")
      |> put_req_header("x-hub-signature-256", signature(body))

    assert {:ok, %{handled: false, reason: "unsupported_event"}} =
             Symphony.GitHubWebhook.handle(conn, payload)
  end

  test "marks merged pull requests as done when the issue identifier is present" do
    payload = %{
      "action" => "closed",
      "number" => 42,
      "pull_request" => %{
        "merged" => true,
        "number" => 42,
        "html_url" => "https://github.com/sboesen/blog.boesen.me/pull/42",
        "title" => "TEST-1 Ship it"
      }
    }

    body = Jason.encode!(payload)

    conn =
      conn(:post, "/api/v1/github/webhook", body)
      |> Plug.Conn.assign(:raw_body, body)
      |> put_req_header("x-github-event", "pull_request")
      |> put_req_header("x-hub-signature-256", signature(body))

    assert {:ok, %{handled: true, issue_identifier: "TEST-1", transition: "done"}} =
             Symphony.GitHubWebhook.handle(conn, payload)
  end

  test "moves changes-requested reviews back to in progress" do
    payload = %{
      "review" => %{"state" => "changes_requested"},
      "pull_request" => %{
        "html_url" => "https://github.com/sboesen/blog.boesen.me/pull/42",
        "title" => "TEST-1 Needs polish"
      }
    }

    body = Jason.encode!(payload)

    conn =
      conn(:post, "/api/v1/github/webhook", body)
      |> Plug.Conn.assign(:raw_body, body)
      |> put_req_header("x-github-event", "pull_request_review")
      |> put_req_header("x-hub-signature-256", signature(body))

    assert {:ok, %{handled: true, issue_identifier: "TEST-1", transition: "in_progress"}} =
             Symphony.GitHubWebhook.handle(conn, payload)
  end

  defp signature(raw_body) do
    digest = :crypto.mac(:hmac, :sha256, "test-secret", raw_body) |> Base.encode16(case: :lower)
    "sha256=" <> digest
  end
end
