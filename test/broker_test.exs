defmodule Symphony.BrokerTest do
  use ExUnit.Case, async: false

  test "register and heartbeat preserve linear routing metadata" do
    session_id = "broker-test-session"

    payload = %{
      session_id: session_id,
      repo: "sboesen/blog.boesen.me",
      callback_url: "http://127.0.0.1:4012/api/v1/github/webhook/#{session_id}",
      linear_callback_url: "http://127.0.0.1:4012/api/v1/linear/webhook/b88fe441c568",
      project_slug: "b88fe441c568",
      issue_identifiers: ["TEST-1"]
    }

    assert {:ok, %{session_id: ^session_id}} = Symphony.Broker.register_session(payload)

    session =
      Symphony.Broker.current().sessions
      |> Enum.find(&(&1.session_id == session_id))

    assert session.linear_callback_url == payload.linear_callback_url
    assert session.project_slug == payload.project_slug

    heartbeat = %{
      session_id: session_id,
      linear_callback_url: "http://127.0.0.1:4013/api/v1/linear/webhook/b88fe441c568",
      issue_identifiers: ["TEST-2"]
    }

    assert {:ok, %{session_id: ^session_id}} = Symphony.Broker.heartbeat(heartbeat)

    session =
      Symphony.Broker.current().sessions
      |> Enum.find(&(&1.session_id == session_id))

    assert session.linear_callback_url == heartbeat.linear_callback_url
    assert session.project_slug == payload.project_slug
    assert session.issue_identifiers == ["TEST-2"]

    assert {:ok, %{session_id: ^session_id}} = Symphony.Broker.unregister_session(%{session_id: session_id})
  end
end
