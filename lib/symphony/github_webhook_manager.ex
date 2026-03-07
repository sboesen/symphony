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
      session_id: Symphony.Broker.session_id() || random_session_id(),
      ngrok_port: nil,
      ngrok_port_handle: nil,
      public_url: nil,
      webhook_id: nil,
      repo: nil,
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
       webhook_id: state.webhook_id,
       repo: state.repo,
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
    _ = cleanup_webhook(state)
    _ = stop_ngrok(state)
    :ok
  end

  defp maybe_register(state) do
    with {:ok, config} <- current_config(),
         true <- Symphony.Broker.owner?(),
         true <- config.github_webhook_auto_register,
         "ngrok" <- config.github_webhook_provider,
         repo when is_binary(repo) and repo != "" <- config.github_webhook_repo,
         secret when is_binary(secret) and secret != "" <- config.github_webhook_secret,
         port when is_integer(port) and port > 0 <- 4051,
         {:ok, state} <- ensure_ngrok(state, port),
         {:ok, public_url} <- fetch_public_url(),
         {:ok, state} <- ensure_webhook(state, repo, secret, public_url) do
      {:ok, %{state | public_url: public_url, repo: repo, last_error: nil}}
    else
      false ->
        {:ok, state}

      nil ->
        {:error, :github_webhook_not_configured, state}

      {:error, reason} ->
        {:error, reason, state}

      other ->
        {:error, other, state}
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

  defp ensure_webhook(state, repo, secret, public_url) do
    callback = callback_url(public_url)

    cond do
      state.webhook_id && state.public_url == public_url && state.repo == repo ->
        {:ok, state}

      true ->
        _ = cleanup_webhook(state)
        _ = cleanup_old_symphony_hooks(repo)

        with {:ok, hook_id} <- create_webhook(repo, secret, callback) do
          Logger.info("registered GitHub webhook for #{repo} -> #{callback}")
          {:ok, %{state | webhook_id: hook_id, public_url: public_url, repo: repo}}
        end
    end
  end

  defp create_webhook(repo, secret, callback) do
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

  defp cleanup_webhook(%{webhook_id: nil}), do: :ok

  defp cleanup_webhook(%{webhook_id: hook_id, repo: repo}) when is_integer(hook_id) and is_binary(repo) do
    _ =
      System.cmd(
        "gh",
        ["api", "--method", "DELETE", "repos/#{repo}/hooks/#{hook_id}"],
        stderr_to_stdout: true
      )

    :ok
  end

  defp cleanup_webhook(_), do: :ok

  defp cleanup_old_symphony_hooks(repo) do
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

  defp stop_ngrok(%{ngrok_port_handle: handle}) when is_port(handle) do
    Port.close(handle)
    :ok
  rescue
    _ -> :ok
  end

  defp stop_ngrok(_), do: :ok

  defp callback_url(public_url), do: public_url <> "/github/webhook"

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

  defp random_session_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
