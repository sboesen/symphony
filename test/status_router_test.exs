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
end
