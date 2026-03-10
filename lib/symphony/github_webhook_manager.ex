defmodule Symphony.GitHubWebhookManager do
  @moduledoc "Optional ngrok + GitHub webhook registration manager for local Symphony sessions."

  use GenServer
  require Logger

  @default_poll_ms 5_000
  @ngrok_api "http://127.0.0.1:4040/api/tunnels"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def current do
    case Process.whereis(__MODULE__) do
      nil -> nil
      _pid -> GenServer.call(__MODULE__, :current)
    end
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    state = %{
      session_id: broker_session_id() || random_session_id(),
      ngrok_port: nil,
      ngrok_port_handle: nil,
      public_url: nil,
      github_webhooks: %{},
      linear_webhooks: %{},
      last_error: nil
    }

    send(self(), :ensure_ready)
    {:ok, state}
  end

  @impl true
  def handle_call(:current, _from, state) do
    {:reply,
     %{
       session_id: state.session_id,
       public_url: state.public_url,
       github_webhooks: state.github_webhooks,
       linear_webhooks: state.linear_webhooks,
       last_error: state.last_error
     }, state}
  end

  @impl true
  def handle_info(:ensure_ready, state) do
    state =
      case maybe_register(state) do
        {:ok, next_state} -> next_state
        {:error, reason, next_state} -> %{next_state | last_error: inspect(reason)}
      end

    Process.send_after(self(), :ensure_ready, @default_poll_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info({_port, {:data, _data}}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({_port, {:exit_status, _status}}, state) do
    {:noreply, %{state | ngrok_port_handle: nil, ngrok_port: nil}}
  end

  @impl true
  def handle_info({:EXIT, port, _reason}, %{ngrok_port_handle: port} = state) do
    {:noreply, %{state | ngrok_port_handle: nil, ngrok_port: nil}}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    _ = stop_ngrok(state)
    :ok
  end

  defp maybe_register(state) do
    with {:ok, config} <- current_config(),
         true <- Symphony.Broker.owner?(),
         "ngrok" <- config.github_webhook_provider,
         true <- config.github_webhook_auto_register or config.linear_webhook_auto_register,
         port when is_integer(port) and port > 0 <- 4051,
         {:ok, state} <- ensure_ngrok(state, port),
         {:ok, public_url} <- fetch_public_url() do
      state = %{state | public_url: public_url}

      {state, errors} =
        {state, []}
        |> reconcile_collect(&reconcile_github_webhooks(&1, config, public_url))
        |> reconcile_collect(&reconcile_linear_webhooks(&1, config, public_url))

      case errors do
        [] -> {:ok, %{state | last_error: nil}}
        [reason | _] -> {:error, reason, %{state | last_error: inspect(reason)}}
      end
    else
      false ->
        {:ok, state}

      {:error, reason} ->
        {:error, reason, state}

      other ->
        {:error, other, state}
    end
  end

  defp reconcile_collect({state, errors}, fun) do
    case fun.(state) do
      {:ok, next_state} -> {next_state, errors}
      {:error, reason} -> {state, errors ++ [reason]}
    end
  end

  defp ensure_ngrok(state, port) when not is_nil(state.ngrok_port_handle) and state.ngrok_port == port do
    {:ok, state}
  end

  defp ensure_ngrok(state, port) do
    with exe when is_binary(exe) <- System.find_executable("ngrok"),
         {:ok, handle} <- spawn_ngrok(exe, port) do
      {:ok, %{state | ngrok_port: port, ngrok_port_handle: handle}}
    else
      nil -> {:error, :ngrok_not_installed}
      error -> error
    end
  end

  defp spawn_ngrok(exe, port) do
    handle =
      Port.open(
        {:spawn_executable, exe},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, ["http", Integer.to_string(port), "--log=stdout"]}
        ]
      )

    {:ok, handle}
  rescue
    error ->
      {:error, {:ngrok_spawn_failed, Exception.message(error)}}
  end

  defp fetch_public_url do
    request = Finch.build(:get, @ngrok_api)

    case Finch.request(request, Symphony.Finch, receive_timeout: 2_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        with {:ok, decoded} <- Jason.decode(body),
             tunnels when is_list(tunnels) <- decoded["tunnels"],
             url when is_binary(url) <- tunnels |> Enum.find_value(& &1["public_url"]) do
          {:ok, url}
        else
          _ -> {:error, :ngrok_public_url_unavailable}
        end

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:ngrok_api_error, status}}

      {:error, reason} ->
        {:error, {:ngrok_api_transport_error, reason}}
    end
  end

  defp reconcile_github_webhooks(state, config, public_url) do
    if config.github_webhook_auto_register do
      secret = config.github_webhook_secret
      callback = callback_url(public_url)

      repos =
        broker_sessions()
        |> List.wrap()
        |> Enum.map(&(&1.repo || &1["repo"]))
        |> Enum.filter(&(is_binary(&1) and &1 != ""))
        |> Enum.uniq()

      with {:ok, next_hooks} <-
             reconcile_desired_github_hooks(state.github_webhooks, repos, secret, callback) do
        {:ok, %{state | github_webhooks: next_hooks}}
      end
    else
      _ = Enum.each(state.github_webhooks, fn {_repo, hook} -> cleanup_github_webhook(hook) end)
      {:ok, %{state | github_webhooks: %{}}}
    end
  end

  defp reconcile_linear_webhooks(state, config, public_url) do
    if config.linear_webhook_auto_register do
      secret = config.linear_webhook_secret

      desired_projects =
        broker_sessions()
        |> List.wrap()
        |> Enum.map(fn session ->
          %{
            project_slug: Map.get(session, :project_slug) || Map.get(session, "project_slug"),
            session_id: Map.get(session, :session_id) || Map.get(session, "session_id")
          }
        end)
        |> Enum.filter(fn session ->
          is_binary(session.project_slug) and session.project_slug != "" and
            is_binary(session.session_id) and session.session_id != ""
        end)
        |> Enum.uniq_by(& &1.project_slug)

      with {:ok, next_hooks} <-
             reconcile_desired_linear_hooks(
               state.linear_webhooks,
               desired_projects,
               secret,
               public_url,
               config
             ) do
        {:ok, %{state | linear_webhooks: next_hooks}}
      end
    else
      _ = Enum.each(state.linear_webhooks, fn {_slug, hook} -> cleanup_linear_webhook(config, hook) end)
      {:ok, %{state | linear_webhooks: %{}}}
    end
  end

  defp reconcile_desired_github_hooks(current_hooks, repos, secret, callback) do
    next_hooks =
      Enum.reduce(Map.keys(current_hooks), current_hooks, fn repo, acc ->
        if repo in repos do
          acc
        else
          _ = cleanup_github_webhook(Map.get(acc, repo))
          Map.delete(acc, repo)
        end
      end)

    Enum.reduce_while(repos, {:ok, next_hooks}, fn repo, {:ok, acc} ->
      hook = Map.get(acc, repo)

      if hook && hook[:callback] == callback do
        {:cont, {:ok, acc}}
      else
        _ = cleanup_github_webhook(hook)
        _ = cleanup_old_symphony_github_hooks(repo)

        case create_github_webhook(repo, secret, callback) do
          {:ok, hook_id} ->
            Logger.info("registered GitHub webhook for #{repo} -> #{callback}")
            {:cont, {:ok, Map.put(acc, repo, %{id: hook_id, repo: repo, callback: callback})}}

          error ->
            {:halt, error}
        end
      end
    end)
  end

  defp reconcile_desired_linear_hooks(current_hooks, desired_projects, secret, public_url, config) do
    next_hooks =
      Enum.reduce(Map.keys(current_hooks), current_hooks, fn slug, acc ->
        if Enum.any?(desired_projects, &(&1.project_slug == slug)) do
          acc
        else
          _ = cleanup_linear_webhook(config, Map.get(acc, slug))
          Map.delete(acc, slug)
        end
      end)

    Enum.reduce_while(desired_projects, {:ok, next_hooks}, fn project, {:ok, acc} ->
      callback = linear_callback_url(public_url, project.project_slug)
      hook = Map.get(acc, project.project_slug)

      if hook && hook[:callback] == callback do
        {:cont, {:ok, acc}}
      else
        _ = cleanup_linear_webhook(config, hook)
        _ = cleanup_old_symphony_linear_hooks(config, project.project_slug)

        case create_linear_webhook(config, project.project_slug, secret, callback) do
          {:ok, webhook} ->
            Logger.info("registered Linear webhook for #{project.project_slug} -> #{callback}")

            {:cont,
             {:ok,
              Map.put(acc, project.project_slug, %{
                id: webhook[:id],
                project_slug: project.project_slug,
                callback: callback
              })}}

          error ->
            {:halt, error}
        end
      end
    end)
  end

  defp create_github_webhook(repo, secret, callback) do
    payload =
      Jason.encode!(%{
        name: "web",
        active: true,
        events: ["pull_request", "pull_request_review"],
        config: %{
          url: callback,
          content_type: "json",
          secret: secret,
          insecure_ssl: "0"
        }
      })

    input_path = Path.join(System.tmp_dir!(), "symphony-github-hook-#{System.unique_integer([:positive])}.json")

    try do
      File.write!(input_path, payload)

      args = [
        "api",
        "--method",
        "POST",
        "repos/#{repo}/hooks",
        "--input",
        input_path
      ]

      case System.cmd("gh", args, stderr_to_stdout: true) do
        {output, 0} ->
          with {:ok, decoded} <- Jason.decode(output),
               hook_id when is_integer(hook_id) <- decoded["id"] do
            {:ok, hook_id}
          else
            _ -> {:error, :github_webhook_create_failed}
          end

        {output, _status} ->
          {:error, {:github_webhook_create_failed, String.trim(output)}}
      end
    after
      File.rm(input_path)
    end
  end

  defp cleanup_github_webhook(nil), do: :ok

  defp cleanup_github_webhook(%{id: hook_id, repo: repo})
       when is_integer(hook_id) and is_binary(repo) do
    _ =
      System.cmd(
        "gh",
        ["api", "--method", "DELETE", "repos/#{repo}/hooks/#{hook_id}"],
        stderr_to_stdout: true
      )

    :ok
  end

  defp cleanup_github_webhook(_), do: :ok

  defp cleanup_old_symphony_github_hooks(repo) do
    with {output, 0} <-
           System.cmd(
             "gh",
             ["api", "repos/#{repo}/hooks"],
             stderr_to_stdout: true
           ),
         {:ok, hooks} <- Jason.decode(output) do
      hooks
      |> Enum.filter(fn hook ->
        url = get_in(hook, ["config", "url"]) || ""
        String.contains?(url, "/api/v1/github/webhook") or String.contains?(url, "/github/webhook")
      end)
      |> Enum.each(fn hook ->
        _ =
          System.cmd(
            "gh",
            ["api", "--method", "DELETE", "repos/#{repo}/hooks/#{hook["id"]}"],
            stderr_to_stdout: true
          )
      end)
    end

    :ok
  end

  defp create_linear_webhook(config, project_slug, secret, callback) do
        with {:ok, project} <- Symphony.Tracker.fetch_project_by_slug(config, project_slug),
             team_id when is_binary(team_id) <- List.first(project.team_ids || []),
             attrs <- %{
               label: "Symphony local webhook (#{project_slug})",
               url: callback,
               secret: secret,
               teamId: team_id,
               resourceTypes: ["Issue", "Comment"]
             },
             {:ok, webhook} <- Symphony.Tracker.create_webhook(config, attrs) do
      {:ok, webhook}
    else
      nil -> {:error, {:linear_project_team_missing, project_slug}}
      {:ok, nil} -> {:error, {:linear_project_not_found, project_slug}}
      false -> {:error, {:linear_project_not_found, project_slug}}
      error -> error
    end
  end

  defp cleanup_linear_webhook(_config, nil), do: :ok

  defp cleanup_linear_webhook(config, %{id: hook_id}) when is_binary(hook_id) do
    case Symphony.Tracker.delete_webhook(config, hook_id) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end

    :ok
  end

  defp cleanup_linear_webhook(_config, _), do: :ok

  defp cleanup_old_symphony_linear_hooks(config, project_slug) do
    with {:ok, project} <- Symphony.Tracker.fetch_project_by_slug(config, project_slug),
         {:ok, webhooks} <- Symphony.Tracker.list_webhooks(config) do
      team_ids = MapSet.new(project.team_ids || [])

      webhooks
      |> Enum.filter(fn hook ->
        url = hook[:url] || ""
        label = hook[:label] || ""
        hook[:team_id] in team_ids and
          (String.contains?(url, "/api/v1/linear/webhook/") or
             String.contains?(url, "/linear/webhook/") or
             String.contains?(label, "Symphony local webhook"))
      end)
      |> Enum.each(fn hook ->
        _ = Symphony.Tracker.delete_webhook(config, hook.id)
      end)
    end

    :ok
  end

  defp stop_ngrok(%{ngrok_port_handle: handle}) when is_port(handle) do
    Port.close(handle)
    :ok
  rescue
    _ -> :ok
  end

  defp stop_ngrok(_), do: :ok

  defp callback_url(public_url), do: public_url <> "/github/webhook"
  defp linear_callback_url(public_url, project_slug), do: public_url <> "/linear/webhook/" <> project_slug

  defp current_config do
    try do
      case Process.whereis(Symphony.Orchestrator) do
        nil ->
          {:error, :config_unavailable}

        _pid ->
          case Symphony.Orchestrator.current_config() do
            %Symphony.Config{} = config -> {:ok, config}
            _ -> {:error, :config_unavailable}
          end
      end
    catch
      :exit, _ -> {:error, :config_unavailable}
    end
  end

  defp broker_state do
    try do
      case Process.whereis(Symphony.Broker) do
        nil ->
          %{sessions: []}

        _pid ->
          GenServer.call(Symphony.Broker, :current, 250)
      end
    catch
      :exit, _ -> %{sessions: []}
    end
  end

  defp broker_sessions do
    broker_state().sessions || []
  end

  defp broker_session_id do
    broker_state()[:session_id]
  end

  defp random_session_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
