defmodule Symphony.BrokerTest do
  use ExUnit.Case, async: false

  alias Plug.Conn

  setup do
    ref = make_ref()
    parent = self()
    :persistent_term.put({__MODULE__, :test_pid}, parent)

    {:ok, _pid} =
      Plug.Cowboy.http(__MODULE__.Router, [], ip: {127, 0, 0, 1}, port: 0, ref: ref)

    port = :ranch.get_port(ref)

    on_exit(fn ->
      :persistent_term.erase({__MODULE__, :test_pid})
      Plug.Cowboy.shutdown(ref)
    end)

    %{base_url: "http://127.0.0.1:#{port}"}
  end

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

  test "register rejects missing session ids and heartbeat does not create new sessions" do
    before_count = length(Symphony.Broker.current().sessions)

    assert {:error, :session_id_missing} = Symphony.Broker.register_session(%{})
    assert {:ok, %{session_id: "missing"}} = Symphony.Broker.heartbeat(%{session_id: "missing"})

    assert length(Symphony.Broker.current().sessions) == before_count
  end

  test "forward_github_webhook routes matching sessions and filters outbound headers", %{base_url: base_url} do
    session_id = "broker-github-session"

    assert {:ok, _} =
             Symphony.Broker.register_session(%{
               session_id: session_id,
               repo: "acme/repo",
               callback_url: base_url <> "/github",
               issue_identifiers: ["TEST-1"]
             })

    body = Jason.encode!(%{"pull_request" => %{"title" => "TEST-1 Ship it"}, "repository" => %{"full_name" => "acme/repo"}})

    headers = [
      {"content-type", "application/json"},
      {"x-github-event", "pull_request"},
      {"x-hub-signature-256", "sha256=test"},
      {"linear-signature", "should-not-pass"}
    ]

    assert {:ok, result} =
             Symphony.Broker.forward_github_webhook(
               body,
               headers,
               Jason.decode!(body)
             )

    assert result.forwarded == 1
    assert result.direct_result == nil
    assert [%{response: %{status: 200, body: echoed}}] = result.results

    echoed_payload = Jason.decode!(echoed)
    assert echoed_payload["headers"]["x-github-event"] == "pull_request"
    assert echoed_payload["headers"]["x-hub-signature-256"] == "sha256=test"
    refute Map.has_key?(echoed_payload["headers"], "linear-signature")
    assert_receive {:broker_echo, :github, _headers, ^body}

    assert {:ok, _} = Symphony.Broker.unregister_session(%{session_id: session_id})
  end

  test "forward_linear_webhook routes by normalized project slug and filters headers", %{base_url: base_url} do
    session_id = "broker-linear-session"

    assert {:ok, _} =
             Symphony.Broker.register_session(%{
               session_id: session_id,
               linear_callback_url: base_url <> "/linear",
               project_slug: "Project-1"
             })

    body = Jason.encode!(%{"action" => "comment"})

    headers = [
      {"content-type", "application/json"},
      {"linear-signature", "linear-secret"},
      {"linear-event", "Comment"},
      {"x-github-event", "should-not-pass"}
    ]

    assert {:ok, result} =
             Symphony.Broker.forward_linear_webhook(
               " project-1 ",
               body,
               headers,
               Jason.decode!(body)
             )

    assert result.forwarded == 1
    assert result.direct_result == nil
    assert [%{response: %{status: 200, body: echoed}}] = result.results

    echoed_payload = Jason.decode!(echoed)
    assert echoed_payload["headers"]["linear-signature"] == "linear-secret"
    assert echoed_payload["headers"]["linear-event"] == "Comment"
    refute Map.has_key?(echoed_payload["headers"], "x-github-event")
    assert_receive {:broker_echo, :linear, _headers, ^body}

    assert {:ok, _} = Symphony.Broker.unregister_session(%{session_id: session_id})
  end

  defmodule Router do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/github" do
      send_echo(conn, :github)
    end

    post "/linear" do
      send_echo(conn, :linear)
    end

    defp send_echo(conn, kind) do
      {:ok, body, conn} = Conn.read_body(conn)
      pid = :persistent_term.get({Symphony.BrokerTest, :test_pid}, nil)
      if is_pid(pid), do: send(pid, {:broker_echo, kind, conn.req_headers, body})

      response =
        Jason.encode!(%{
          headers: Map.new(conn.req_headers),
          body: body
        })

      Conn.send_resp(conn, 200, response)
    end
  end
end
