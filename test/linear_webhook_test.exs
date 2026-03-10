defmodule Symphony.LinearWebhookTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  test "rejects invalid signatures" do
    payload = %{"action" => "Issue"}
    body = Jason.encode!(payload)

    conn =
      conn(:post, "/api/v1/linear/webhook/blogboesenme-b88fe441c568", body)
      |> Plug.Conn.assign(:raw_body, body)
      |> put_req_header("linear-signature", "bad")

    assert {:error, :invalid_linear_signature} = Symphony.LinearWebhook.handle(conn, payload)
  end

  test "rejects mismatched project slugs" do
    payload = %{"action" => "Issue"}
    body = Jason.encode!(payload)

    conn =
      conn(:post, "/api/v1/linear/webhook/other-project", body)
      |> Plug.Conn.assign(:raw_body, body)
      |> put_req_header("linear-signature", signature(body))

    assert {:error, :invalid_linear_webhook_project} =
             Symphony.LinearWebhook.handle(conn, payload, "other-project")
  end

  test "accepts signed payloads and triggers refresh" do
    payload = %{
      "action" => "Issue",
      "data" => %{"identifier" => "TEST-1", "state" => %{"name" => "Todo"}}
    }
    body = Jason.encode!(payload)

    conn =
      conn(:post, "/api/v1/linear/webhook", body)
      |> Plug.Conn.assign(:raw_body, body)
      |> put_req_header("linear-signature", signature(body))

    assert {:ok, %{handled: true, refreshed: true, issue_identifier: "TEST-1"}} =
             Symphony.LinearWebhook.handle(conn, payload)
  end

  test "ignores Symphony-managed comment events" do
    payload = %{
      "action" => "Comment",
      "data" => %{
        "identifier" => "TEST-1",
        "body" => "[Symphony:plan]\n## Plan\n- [ ] Something"
      }
    }

    body = Jason.encode!(payload)

    conn =
      conn(:post, "/api/v1/linear/webhook", body)
      |> Plug.Conn.assign(:raw_body, body)
      |> put_req_header("linear-signature", signature(body))

    assert {:ok, %{handled: true, refreshed: false, issue_identifier: "TEST-1"}} =
             Symphony.LinearWebhook.handle(conn, payload)
  end

  test "refreshes on non-Symphony comment events" do
    payload = %{
      "action" => "Comment",
      "data" => %{
        "identifier" => "TEST-1",
        "body" => "Please adjust the spacing."
      }
    }

    body = Jason.encode!(payload)

    conn =
      conn(:post, "/api/v1/linear/webhook", body)
      |> Plug.Conn.assign(:raw_body, body)
      |> put_req_header("linear-signature", signature(body))

    assert {:ok, %{handled: true, refreshed: true, issue_identifier: "TEST-1"}} =
             Symphony.LinearWebhook.handle(conn, payload)
  end

  test "does not refresh on non-state issue-adjacent create events" do
    payload = %{
      "action" => "Create",
      "data" => %{
        "identifier" => "TEST-1",
        "title" => "Recording artifact"
      }
    }

    body = Jason.encode!(payload)

    conn =
      conn(:post, "/api/v1/linear/webhook", body)
      |> Plug.Conn.assign(:raw_body, body)
      |> put_req_header("linear-signature", signature(body))

    assert {:ok, %{handled: true, refreshed: false, issue_identifier: "TEST-1"}} =
             Symphony.LinearWebhook.handle(conn, payload)
  end

  defp signature(raw_body) do
    :crypto.mac(:hmac, :sha256, "test-secret", raw_body) |> Base.encode16(case: :lower)
  end
end
