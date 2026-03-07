defmodule Symphony.Broker do
  @moduledoc "Embedded local broker that owns one webhook ingress and fans events out to local Symphony sessions."

  use GenServer
  require Logger

  @broker_port 4051
  @heartbeat_ms 5_000
  @stale_after_ms 20_000
  @cowboy_ref __MODULE__.HTTP

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def current do
    case Process.whereis(__MODULE__) do
      nil -> %{owner: false, broker_port: @broker_port, sessions: []}
      _pid -> GenServer.call(__MODULE__, :current)
    end
  end

  def owner? do
    case current() do
      %{owner: true} -> true
      _ -> false
    end
  end

  def session_id do
    case current() do
      %{session_id: value} -> value
      _ -> nil
    end
  end

  def register_session(payload), do: GenServer.call(__MODULE__, {:register, payload})
  def heartbeat(payload), do: GenServer.call(__MODULE__, {:heartbeat, payload})
  def unregister_session(payload), do: GenServer.call(__MODULE__, {:unregister, payload})

  def forward_github_webhook(raw_body, headers, payload) do
    GenServer.call(__MODULE__, {:forward_webhook, raw_body, headers, payload}, 15_000)
  end

  @impl true
  def init(_) do
    session_id = random_session_id()

    state = %{
      owner: false,
      session_id: session_id,
      sessions: %{},
      public_webhook_url: nil,
      repo: nil,
      callback_url: nil,
      registered?: false,
      last_error: nil
    }

    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_call(:current, _from, state) do
    {:reply,
     %{
       owner: state.owner,
       broker_port: @broker_port,
       session_id: state.session_id,
       public_webhook_url: state.public_webhook_url,
       repo: state.repo,
       registered?: state.registered?,
       sessions: Enum.map(state.sessions, fn {_id, session} -> session end),
       last_error: state.last_error
     }, state}
  end

  def handle_call({:register, payload}, _from, state) do
    session_id = payload["session_id"] || payload[:session_id]

    if is_binary(session_id) and session_id != "" do
      session = %{
        session_id: session_id,
        repo: payload["repo"] || payload[:repo],
        callback_url: payload["callback_url"] || payload[:callback_url],
        process_id: payload["process_id"] || payload[:process_id],
        issue_identifiers: payload["issue_identifiers"] || payload[:issue_identifiers] || [],
        last_seen_ms: now_ms()
      }

      {:reply, {:ok, %{session_id: session_id}}, %{state | sessions: Map.put(state.sessions, session_id, session)}}
    else
      {:reply, {:error, :session_id_missing}, state}
    end
  end

  def handle_call({:heartbeat, payload}, _from, state) do
    session_id = payload["session_id"] || payload[:session_id]

    next_state =
      case Map.get(state.sessions, session_id) do
        nil ->
          state

        session ->
          updated =
            session
            |> Map.put(:last_seen_ms, now_ms())
            |> Map.put(:issue_identifiers, payload["issue_identifiers"] || payload[:issue_identifiers] || session.issue_identifiers)

          %{state | sessions: Map.put(state.sessions, session_id, updated)}
      end

    {:reply, {:ok, %{session_id: session_id}}, next_state}
  end

  def handle_call({:unregister, payload}, _from, state) do
    session_id = payload["session_id"] || payload[:session_id]
    {:reply, {:ok, %{session_id: session_id}}, %{state | sessions: Map.delete(state.sessions, session_id)}}
  end

  def handle_call({:forward_webhook, raw_body, headers, payload}, _from, state) do
    repo = get_in(payload, ["repository", "full_name"])
    issue_identifier = extract_issue_identifier(payload)

    matched =
      state.sessions
      |> Map.values()
      |> Enum.filter(fn session ->
        is_binary(session.callback_url) and session.callback_url != "" and
          (is_nil(repo) or is_nil(session.repo) or session.repo == repo) and
          route_to_session?(session, issue_identifier)
      end)

    results =
      Enum.map(matched, fn session ->
        %{
          session_id: session.session_id,
          response: forward_to_session(session.callback_url, raw_body, headers)
        }
      end)

    {:reply, {:ok, %{forwarded: length(matched), repo: repo, results: results}}, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state =
      state
      |> maybe_become_owner()
      |> maybe_register_local_session()
      |> prune_stale_sessions()

    Process.send_after(self(), :tick, @heartbeat_ms)
    {:noreply, state}
  end

  defp maybe_become_owner(state) do
    cond do
      state.owner ->
        state

      broker_alive?() ->
        state

      true ->
        case Plug.Cowboy.http(Symphony.BrokerRouter, [], ip: {127, 0, 0, 1}, port: @broker_port, ref: @cowboy_ref) do
          {:ok, _pid} ->
            Logger.info("broker listening on 127.0.0.1:#{@broker_port}")
            %{state | owner: true}

          {:error, _} ->
            state
        end
    end
  end

  defp maybe_register_local_session(state) do
    with {:ok, config} <- current_config(),
         port when is_integer(port) and port > 0 <- config.server_port do
      callback_url = "http://127.0.0.1:#{port}/api/v1/github/webhook/#{state.session_id}"
      repo = config.github_webhook_repo
      issues = local_issue_identifiers(config)

      payload = %{
        session_id: state.session_id,
        repo: repo,
        callback_url: callback_url,
        process_id: inspect(self()),
        issue_identifiers: issues
      }

      if state.owner do
        session = %{
          session_id: state.session_id,
          repo: repo,
          callback_url: callback_url,
          process_id: inspect(self()),
          issue_identifiers: issues,
          last_seen_ms: now_ms()
        }

        %{state | repo: repo, callback_url: callback_url, registered?: true, last_error: nil, sessions: Map.put(state.sessions, state.session_id, session)}
      else
        case post_json("http://127.0.0.1:#{@broker_port}/register", payload) do
          {:ok, _} ->
            _ = post_json("http://127.0.0.1:#{@broker_port}/heartbeat", payload)
            %{state | repo: repo, callback_url: callback_url, registered?: true, last_error: nil}

          {:error, reason} ->
            %{state | registered?: false, last_error: inspect(reason)}
        end
      end
    else
      _ -> state
    end
  end

  defp prune_stale_sessions(state) do
    cutoff = now_ms() - @stale_after_ms

    sessions =
      Enum.reduce(state.sessions, %{}, fn {session_id, session}, acc ->
        if (session.last_seen_ms || 0) >= cutoff do
          Map.put(acc, session_id, session)
        else
          acc
        end
      end)

    %{state | sessions: sessions}
  end

  defp broker_alive? do
    request = Finch.build(:get, "http://127.0.0.1:#{@broker_port}/health")

    case Finch.request(request, Symphony.Finch, receive_timeout: 500) do
      {:ok, %Finch.Response{status: 200}} -> true
      _ -> false
    end
  end

  defp forward_to_session(url, raw_body, headers) do
    outbound_headers =
      headers
      |> Enum.filter(fn {key, _} ->
        key in ["content-type", "x-github-event", "x-hub-signature-256"]
      end)

    request = Finch.build(:post, url, outbound_headers, raw_body)

    case Finch.request(request, Symphony.Finch, receive_timeout: 5_000) do
      {:ok, %Finch.Response{status: status, body: body}} ->
        %{status: status, body: body}

      {:error, reason} ->
        %{error: inspect(reason)}
    end
  end

  defp post_json(url, payload) do
    request = Finch.build(:post, url, [{"content-type", "application/json"}], Jason.encode!(payload))

    case Finch.request(request, Symphony.Finch, receive_timeout: 2_000) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 -> {:ok, :sent}
      {:ok, %Finch.Response{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp current_config do
    try do
      case Process.whereis(Symphony.Orchestrator) do
        nil -> {:error, :config_unavailable}
        _pid -> {:ok, Symphony.Orchestrator.current_config()}
      end
    rescue
      _ -> {:error, :config_unavailable}
    catch
      :exit, _ -> {:error, :config_unavailable}
    end
  end

  defp local_issue_identifiers(config) do
    case Symphony.Tracker.fetch_candidates(config) do
      {:ok, issues} -> Enum.map(issues, & &1.identifier)
      _ -> []
    end
  end

  defp route_to_session?(_session, nil), do: true

  defp route_to_session?(session, issue_identifier) do
    issues = session.issue_identifiers || []
    issues == [] or issue_identifier in issues
  end

  defp extract_issue_identifier(%{"pull_request" => pr}) when is_map(pr) do
    title = to_string(pr["title"] || "")
    body = to_string(pr["body"] || "")
    head_ref = get_in(pr, ["head", "ref"]) || pr["headRefName"] || ""

    cond do
      match = Regex.run(~r/\b([A-Z][A-Z0-9]+-\d+)\b/, title, capture: :all_but_first) ->
        List.first(match)

      match = Regex.run(~r/\/issue\/([A-Z][A-Z0-9]+-\d+)\b/, body, capture: :all_but_first) ->
        List.first(match)

      match = Regex.run(~r/\b([a-z][a-z0-9]+-\d+)\b/i, to_string(head_ref), capture: :all_but_first) ->
        match |> List.first() |> String.upcase()

      true ->
        nil
    end
  end

  defp extract_issue_identifier(_), do: nil

  defp random_session_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
