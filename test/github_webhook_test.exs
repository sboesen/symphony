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

  test "marks opened pull requests as in review when the issue identifier is present" do
    Process.put(:symphony_tracker_test_pid, self())

    on_exit(fn ->
      Process.delete(:symphony_tracker_test_pid)
    end)

    payload = %{
      "action" => "opened",
      "number" => 43,
      "pull_request" => %{
        "merged" => false,
        "number" => 43,
        "html_url" => "https://github.com/sboesen/blog.boesen.me/pull/43",
        "title" => "TEST-1 Needs review"
      }
    }

    body = Jason.encode!(payload)

    conn =
      conn(:post, "/api/v1/github/webhook", body)
      |> Plug.Conn.assign(:raw_body, body)
      |> put_req_header("x-github-event", "pull_request")
      |> put_req_header("x-hub-signature-256", signature(body))

    assert {:ok, %{handled: true, issue_identifier: "TEST-1", transition: "in_review"}} =
             Symphony.GitHubWebhook.handle(conn, payload)

    assert_receive {:mark_in_review, "TEST-1"}
  end

  test "does not move draft pull requests into review on open" do
    Process.put(:symphony_tracker_test_pid, self())

    on_exit(fn ->
      Process.delete(:symphony_tracker_test_pid)
    end)

    payload = %{
      "action" => "opened",
      "number" => 43,
      "pull_request" => %{
        "draft" => true,
        "merged" => false,
        "number" => 43,
        "html_url" => "https://github.com/sboesen/blog.boesen.me/pull/43",
        "title" => "TEST-1 Draft review"
      }
    }

    body = Jason.encode!(payload)

    conn =
      conn(:post, "/api/v1/github/webhook", body)
      |> Plug.Conn.assign(:raw_body, body)
      |> put_req_header("x-github-event", "pull_request")
      |> put_req_header("x-hub-signature-256", signature(body))

    assert {:ok, %{handled: false, issue_identifier: "TEST-1", reason: "draft_pull_request"}} =
             Symphony.GitHubWebhook.handle(conn, payload)

    refute_receive {:mark_in_review, _}
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

  test "moves approved reviews back to in review" do
    Process.put(:symphony_tracker_test_pid, self())

    on_exit(fn ->
      Process.delete(:symphony_tracker_test_pid)
    end)

    payload = %{
      "review" => %{"state" => "approved"},
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

    assert {:ok, %{handled: true, issue_identifier: "TEST-1", transition: "in_review"}} =
             Symphony.GitHubWebhook.handle(conn, payload)

    assert_receive {:mark_in_review, "TEST-1"}
  end

  test "moves pull request issue comments back to in progress and requests retry" do
    Process.put(:symphony_tracker_test_pid, self())

    on_exit(fn ->
      Process.delete(:symphony_tracker_test_pid)
    end)

    payload = %{
      "action" => "created",
      "issue" => %{
        "html_url" => "https://github.com/sboesen/blog.boesen.me/pull/42",
        "title" => "TEST-1 Needs polish",
        "pull_request" => %{"url" => "https://api.github.com/repos/sboesen/blog.boesen.me/pulls/42"}
      },
      "comment" => %{
        "html_url" => "https://github.com/sboesen/blog.boesen.me/pull/42#issuecomment-1",
        "body" => "Please tighten the animation timing."
      }
    }

    body = Jason.encode!(payload)

    conn =
      conn(:post, "/api/v1/github/webhook", body)
      |> Plug.Conn.assign(:raw_body, body)
      |> put_req_header("x-github-event", "issue_comment")
      |> put_req_header("x-hub-signature-256", signature(body))

    assert {:ok,
            %{handled: true, issue_identifier: "TEST-1", transition: "in_progress", event: "issue_comment"}} =
             Symphony.GitHubWebhook.handle(conn, payload)

    assert_receive {:mark_started, "TEST-1"}
  end

  test "moves pull request review comments back to in progress and requests retry" do
    Process.put(:symphony_tracker_test_pid, self())

    on_exit(fn ->
      Process.delete(:symphony_tracker_test_pid)
    end)

    payload = %{
      "action" => "created",
      "pull_request" => %{
        "html_url" => "https://github.com/sboesen/blog.boesen.me/pull/42",
        "title" => "TEST-1 Needs polish"
      },
      "comment" => %{
        "html_url" => "https://github.com/sboesen/blog.boesen.me/pull/42#discussion_r1",
        "body" => "Can you simplify this interaction?"
      }
    }

    body = Jason.encode!(payload)

    conn =
      conn(:post, "/api/v1/github/webhook", body)
      |> Plug.Conn.assign(:raw_body, body)
      |> put_req_header("x-github-event", "pull_request_review_comment")
      |> put_req_header("x-hub-signature-256", signature(body))

    assert {:ok,
            %{handled: true, issue_identifier: "TEST-1", transition: "in_progress", event: "pull_request_review_comment"}} =
             Symphony.GitHubWebhook.handle(conn, payload)

    assert_receive {:mark_started, "TEST-1"}
  end

  test "ignores issue comments that are not on pull requests" do
    payload = %{
      "action" => "created",
      "issue" => %{
        "html_url" => "https://github.com/sboesen/blog.boesen.me/issues/42",
        "title" => "TEST-1 Needs polish"
      },
      "comment" => %{
        "body" => "This is a regular issue comment."
      }
    }

    body = Jason.encode!(payload)

    conn =
      conn(:post, "/api/v1/github/webhook", body)
      |> Plug.Conn.assign(:raw_body, body)
      |> put_req_header("x-github-event", "issue_comment")
      |> put_req_header("x-hub-signature-256", signature(body))

    assert {:ok, %{handled: false, reason: "not_pull_request_comment"}} =
             Symphony.GitHubWebhook.handle(conn, payload)
  end

  test "broker falls back to direct webhook handling when no live session matches" do
    payload = %{
      "action" => "closed",
      "number" => 44,
      "repository" => %{"full_name" => "sboesen/blog.boesen.me"},
      "pull_request" => %{
        "merged" => true,
        "number" => 44,
        "html_url" => "https://github.com/sboesen/blog.boesen.me/pull/44",
        "title" => "TEST-1 Ship it"
      }
    }

    body = Jason.encode!(payload)

    headers = [
      {"content-type", "application/json"},
      {"x-github-event", "pull_request"},
      {"x-hub-signature-256", signature(body)}
    ]

    assert {:ok, result} = Symphony.Broker.forward_github_webhook(body, headers, payload)
    assert result.issue_identifier == "TEST-1"

    direct_or_forwarded =
      result.direct_result ||
        Enum.find_value(result.results, fn entry ->
          body = entry[:response][:body] || entry["response"]["body"] || ""

          if String.contains?(body, "\"transition\":\"done\"") do
            body
          else
            nil
          end
        end)

    refute is_nil(direct_or_forwarded)
  end

  defp signature(raw_body) do
    digest = :crypto.mac(:hmac, :sha256, "test-secret", raw_body) |> Base.encode16(case: :lower)
    "sha256=" <> digest
  end
end
