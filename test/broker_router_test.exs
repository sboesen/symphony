defmodule Symphony.BrokerRouterTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  test "health endpoint returns ok" do
    conn = Symphony.BrokerRouter.call(conn(:get, "/health"), [])

    assert conn.status == 200
    assert conn.resp_body == "ok"
  end

  test "state endpoint returns broker payload" do
    conn = Symphony.BrokerRouter.call(conn(:get, "/state"), [])

    assert conn.status == 200

    payload = Jason.decode!(conn.resp_body)
    assert payload["owner"] in [true, false]
    assert is_list(payload["sessions"])
  end

  test "register, heartbeat, and unregister endpoints round-trip broker session data" do
    session_id = "broker-router-session"

    register_conn =
      conn(:post, "/register", Jason.encode!(%{session_id: session_id}))
      |> put_req_header("content-type", "application/json")
      |> Symphony.BrokerRouter.call([])

    assert register_conn.status == 200

    assert Jason.decode!(register_conn.resp_body) == %{
             "ok" => true,
             "payload" => %{"session_id" => session_id}
           }

    heartbeat_conn =
      conn(
        :post,
        "/heartbeat",
        Jason.encode!(%{session_id: session_id, issue_identifiers: ["TEST-1"]})
      )
      |> put_req_header("content-type", "application/json")
      |> Symphony.BrokerRouter.call([])

    assert heartbeat_conn.status == 200

    unregister_conn =
      conn(:post, "/unregister", Jason.encode!(%{session_id: session_id}))
      |> put_req_header("content-type", "application/json")
      |> Symphony.BrokerRouter.call([])

    assert unregister_conn.status == 200
  end

  test "register endpoint returns validation errors" do
    conn =
      conn(:post, "/register", Jason.encode!(%{}))
      |> put_req_header("content-type", "application/json")
      |> Symphony.BrokerRouter.call([])

    assert conn.status == 422
    assert Jason.decode!(conn.resp_body)["ok"] == false
  end

  test "unknown route returns not found" do
    conn = Symphony.BrokerRouter.call(conn(:get, "/missing"), [])

    assert conn.status == 404
    assert conn.resp_body == "not found"
  end
end
