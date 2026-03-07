defmodule Symphony.BrokerRouter do
  @moduledoc "Local embedded broker HTTP surface for session registration and webhook fanout."

  use Plug.Router
  import Plug.Conn

  plug(Plug.Parsers,
    parsers: [:urlencoded, :json],
    json_decoder: Jason,
    body_reader: {Symphony.StatusRouter, :read_body, []}
  )
  plug(:match)
  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  get "/state" do
    body = Jason.encode!(Symphony.Broker.current())

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  post "/register" do
    respond(conn, Symphony.Broker.register_session(conn.body_params))
  end

  post "/heartbeat" do
    respond(conn, Symphony.Broker.heartbeat(conn.body_params))
  end

  post "/unregister" do
    respond(conn, Symphony.Broker.unregister_session(conn.body_params))
  end

  post "/github/webhook" do
    respond(
      conn,
      Symphony.Broker.forward_github_webhook(
        conn.assigns[:raw_body] || "",
        conn.req_headers,
        conn.body_params
      )
    )
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp respond(conn, {:ok, payload}) do
    body = Jason.encode!(%{ok: true, payload: payload})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  defp respond(conn, {:error, reason}) do
    body = Jason.encode!(%{ok: false, error: inspect(reason)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(422, body)
  end
end
