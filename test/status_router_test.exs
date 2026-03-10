defmodule Symphony.StatusRouterTest do
  use ExUnit.Case, async: false

  import Plug.Test

  test "health endpoint returns ok" do
    conn = conn(:get, "/health")
    conn = Symphony.StatusRouter.call(conn, [])

    assert conn.status == 200
    assert conn.resp_body == "ok"
  end

  test "root dashboard renders operator desk and demo section shell" do
    conn = conn(:get, "/")
    conn = Symphony.StatusRouter.call(conn, [])

    assert conn.status == 200
    assert conn.resp_body =~ "Symphony Operator Desk"
    assert conn.resp_body =~ "function renderDemo"
  end

  test "status endpoint returns orchestrator payload" do
    conn = conn(:get, "/status")
    conn = Symphony.StatusRouter.call(conn, [])

    assert conn.status == 200

    payload = Jason.decode!(conn.resp_body)
    assert is_boolean(payload["paused"])
    assert is_list(payload["events"])
    assert is_map(payload["config"])
    assert Map.has_key?(payload, "recent_runs")
  end

  test "pause and resume endpoints return ok payloads" do
    pause_conn = Symphony.StatusRouter.call(conn(:post, "/api/v1/pause"), [])
    assert pause_conn.status == 200
    assert Jason.decode!(pause_conn.resp_body) == %{"ok" => true, "payload" => %{"paused" => true}}

    resume_conn = Symphony.StatusRouter.call(conn(:post, "/api/v1/resume"), [])
    assert resume_conn.status == 200
    assert Jason.decode!(resume_conn.resp_body) == %{"ok" => true, "payload" => %{"paused" => false}}
  end

  test "unknown issue status returns 404" do
    conn = conn(:get, "/status/DOES-NOT-EXIST")
    conn = Symphony.StatusRouter.call(conn, [])

    assert conn.status == 404
  end

  test "known issue status returns JSON payload" do
    conn = conn(:get, "/status/TEST-1")
    conn = Symphony.StatusRouter.call(conn, [])

    assert conn.status == 200

    payload = Jason.decode!(conn.resp_body)
    assert payload["issue_identifier"] == "TEST-1"
  end

  test "refresh endpoint returns orchestrator payload" do
    conn = Symphony.StatusRouter.call(conn(:post, "/api/v1/refresh"), [])

    assert conn.status == 200

    payload = Jason.decode!(conn.resp_body)
    assert payload["ok"] == true
    assert is_boolean(payload["payload"]["paused"])
  end

  test "retry and cancel endpoints surface orchestrator errors" do
    retry_conn = Symphony.StatusRouter.call(conn(:post, "/api/v1/issues/TEST-404/retry"), [])
    assert retry_conn.status == 422
    assert Jason.decode!(retry_conn.resp_body) == %{"ok" => false, "error" => ":issue_not_found"}

    cancel_conn = Symphony.StatusRouter.call(conn(:post, "/api/v1/issues/TEST-404/cancel"), [])
    assert cancel_conn.status == 422
    assert Jason.decode!(cancel_conn.resp_body) == %{"ok" => false, "error" => ":issue_not_running"}
  end

  test "github webhook endpoint returns handled payload for signed requests" do
    body = Jason.encode!(%{"zen" => "keep it logically awesome"})

    conn =
      conn(:post, "/api/v1/github/webhook", body)
      |> Plug.Conn.assign(:raw_body, body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-github-event", "ping")
      |> Plug.Conn.put_req_header("x-hub-signature-256", github_signature(body))
      |> Symphony.StatusRouter.call([])

    assert conn.status == 200

    payload = Jason.decode!(conn.resp_body)
    assert payload == %{"ok" => true, "payload" => %{"handled" => false, "reason" => "unsupported_event"}}
  end

  test "github webhook session endpoint rejects stale session ids" do
    body = Jason.encode!(%{"action" => "ping"})

    conn =
      conn(:post, "/api/v1/github/webhook/stale-session", body)
      |> Plug.Conn.assign(:raw_body, body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-github-event", "ping")
      |> Plug.Conn.put_req_header("x-hub-signature-256", github_signature(body))
      |> Symphony.StatusRouter.call([])

    assert conn.status == 422
    assert Jason.decode!(conn.resp_body) == %{"ok" => false, "error" => ":invalid_webhook_session"}
  end

  test "linear webhook endpoint returns handled payload for signed requests" do
    config = Symphony.Orchestrator.current_config()
    body = Jason.encode!(%{"action" => "comment", "data" => %{"body" => "hello"}})

    conn =
      conn(:post, "/api/v1/linear/webhook", body)
      |> Plug.Conn.assign(:raw_body, body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("linear-signature", linear_signature(config.linear_webhook_secret, body))
      |> Symphony.StatusRouter.call([])

    assert conn.status == 200

    payload = Jason.decode!(conn.resp_body)
    assert payload["ok"] == true
    assert payload["payload"]["handled"] == true
    assert payload["payload"]["event_type"] == "comment"
  end

  defp github_signature(raw_body) do
    digest = :crypto.mac(:hmac, :sha256, "test-secret", raw_body) |> Base.encode16(case: :lower)
    "sha256=" <> digest
  end

  defp linear_signature(secret, raw_body) do
    :crypto.mac(:hmac, :sha256, secret, raw_body) |> Base.encode16(case: :lower)
  end
end
