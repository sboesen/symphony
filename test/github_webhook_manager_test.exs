defmodule Symphony.GitHubWebhookManagerTest do
  use ExUnit.Case, async: false

  alias Plug.Conn

  test "current exposes session metadata" do
    current = Symphony.GitHubWebhookManager.current()

    assert is_map(current)
    assert is_binary(current.session_id)
    assert Map.has_key?(current, :public_url)
    assert is_map(current.github_webhooks)
    assert is_map(current.linear_webhooks)
  end

  test "exit-status message clears tracked ngrok handle state" do
    manager = Process.whereis(Symphony.GitHubWebhookManager)
    original = :sys.get_state(manager)
    port = Port.open({:spawn_executable, System.find_executable("bash") || "/bin/bash"}, [:binary, :exit_status, {:args, ["-lc", "sleep 5"]}])

    :sys.replace_state(manager, fn _ ->
      %{original | ngrok_port_handle: port, ngrok_port: 4040}
    end)

    send(manager, {port, {:exit_status, 1}})
    Process.sleep(25)

    current = Symphony.GitHubWebhookManager.current()
    assert current

    state = :sys.get_state(manager)
    assert state.ngrok_port_handle == nil
    assert state.ngrok_port == nil

    Port.close(port)
    :sys.replace_state(manager, fn _ -> original end)
  end

  test "linked exit message only clears matching ngrok handles" do
    manager = Process.whereis(Symphony.GitHubWebhookManager)
    original = :sys.get_state(manager)
    tracked = Port.open({:spawn_executable, System.find_executable("bash") || "/bin/bash"}, [:binary, :exit_status, {:args, ["-lc", "sleep 5"]}])
    other = Port.open({:spawn_executable, System.find_executable("bash") || "/bin/bash"}, [:binary, :exit_status, {:args, ["-lc", "sleep 5"]}])

    on_exit(fn ->
      for port <- [tracked, other] do
        try do
          Port.close(port)
        rescue
          _ -> :ok
        end
      end

      :sys.replace_state(manager, fn _ -> original end)
    end)

    :sys.replace_state(manager, fn _ ->
      %{original | ngrok_port_handle: tracked, ngrok_port: 4040}
    end)

    send(manager, {:EXIT, other, :shutdown})
    Process.sleep(25)
    refute is_nil(:sys.get_state(manager).ngrok_port_handle)

    send(manager, {:EXIT, tracked, :shutdown})
    Process.sleep(25)

    state = :sys.get_state(manager)
    assert state.ngrok_port_handle == nil
    assert state.ngrok_port == nil
  end

  test "ensure_ready registers github webhooks through ngrok" do
    manager = Process.whereis(Symphony.GitHubWebhookManager)
    orchestrator = Process.whereis(Symphony.Orchestrator)
    broker = Process.whereis(Symphony.Broker)
    original_manager = :sys.get_state(manager)
    original_orchestrator = :sys.get_state(orchestrator)
    original_broker = :sys.get_state(broker)

    root = Path.join(System.tmp_dir!(), "symphony-ghwm-#{System.unique_integer([:positive])}")
    bin_dir = Path.join(root, "bin")
    File.mkdir_p!(bin_dir)

    ngrok_path = Path.join(bin_dir, "ngrok")
    gh_path = Path.join(bin_dir, "gh")
    original_path = System.get_env("PATH") || ""
    ref = make_ref()

    File.write!(
      ngrok_path,
      """
      #!/bin/bash
      sleep 30
      """
    )

    File.write!(
      gh_path,
      """
      #!/usr/bin/env python3
      import json, sys
      args = sys.argv[1:]
      if args[:4] == ["api", "--method", "POST", "repos/acme/repo/hooks"]:
          print(json.dumps({"id": 123}), end="")
      elif args[:2] == ["api", "repos/acme/repo/hooks"]:
          print("[]", end="")
      else:
          print("{}", end="")
      """
    )

    File.chmod!(ngrok_path, 0o755)
    File.chmod!(gh_path, 0o755)
    System.put_env("PATH", bin_dir <> ":" <> original_path)

    case Plug.Cowboy.http(__MODULE__.NgrokRouter, [], ip: {127, 0, 0, 1}, port: 4040, ref: ref) do
      {:ok, _pid} ->
        on_exit(fn ->
          current_state = :sys.get_state(manager)

          if is_port(current_state.ngrok_port_handle) do
            try do
              Port.close(current_state.ngrok_port_handle)
            rescue
              _ -> :ok
            end
          end

          :sys.replace_state(manager, fn _ -> original_manager end)
          :sys.replace_state(orchestrator, fn _ -> original_orchestrator end)
          :sys.replace_state(broker, fn _ -> original_broker end)
          System.put_env("PATH", original_path)
          Plug.Cowboy.shutdown(ref)
          File.rm_rf!(root)
        end)

        :sys.replace_state(orchestrator, fn state ->
          config =
            %{state.config |
              github_webhook_provider: "ngrok",
              github_webhook_auto_register: true,
              linear_webhook_auto_register: false,
              github_webhook_secret: "secret"}

          %{state | config: config}
        end)

        :sys.replace_state(broker, fn state ->
          %{state |
            owner: true,
            session_id: "session-1",
            sessions: %{
              "session-1" => %{session_id: "session-1", repo: "acme/repo", project_slug: nil}
            }}
        end)

        :sys.replace_state(manager, fn _ ->
          %{original_manager | public_url: nil, github_webhooks: %{}, linear_webhooks: %{}, last_error: nil}
        end)

        send(manager, :ensure_ready)
        current =
          wait_for_current(fn current ->
            current.public_url == "https://example.ngrok.app" and
              current.github_webhooks["acme/repo"] != nil
          end)

        assert current.public_url == "https://example.ngrok.app"
        assert current.github_webhooks["acme/repo"] == %{id: 123, repo: "acme/repo", callback: "https://example.ngrok.app/github/webhook"}
        assert current.linear_webhooks == %{}
        assert current.last_error == nil

      {:error, :eaddrinuse} ->
        System.put_env("PATH", original_path)
        File.rm_rf!(root)
        assert true
    end
  end

  test "ensure_ready registers github comment webhook events through ngrok" do
    manager = Process.whereis(Symphony.GitHubWebhookManager)
    orchestrator = Process.whereis(Symphony.Orchestrator)
    broker = Process.whereis(Symphony.Broker)
    original_manager = :sys.get_state(manager)
    original_orchestrator = :sys.get_state(orchestrator)
    original_broker = :sys.get_state(broker)

    root = Path.join(System.tmp_dir!(), "symphony-ghwm-events-#{System.unique_integer([:positive])}")
    bin_dir = Path.join(root, "bin")
    File.mkdir_p!(bin_dir)

    ngrok_path = Path.join(bin_dir, "ngrok")
    gh_path = Path.join(bin_dir, "gh")
    payload_log = Path.join(root, "gh_payload.json")
    original_path = System.get_env("PATH") || ""
    ref = make_ref()

    File.write!(ngrok_path, "#!/bin/bash\nsleep 30\n")

    File.write!(
      gh_path,
      """
      #!/usr/bin/env python3
      import json, pathlib, sys

      args = sys.argv[1:]
      payload_path = pathlib.Path("#{payload_log}")

      if args[:4] == ["api", "--method", "POST", "repos/acme/repo/hooks"]:
          input_idx = args.index("--input")
          source = pathlib.Path(args[input_idx + 1])
          payload_path.write_text(source.read_text())
          print(json.dumps({"id": 123}), end="")
      elif args[:2] == ["api", "repos/acme/repo/hooks"]:
          print("[]", end="")
      else:
          print("{}", end="")
      """
    )

    File.chmod!(ngrok_path, 0o755)
    File.chmod!(gh_path, 0o755)
    System.put_env("PATH", bin_dir <> ":" <> original_path)

    case Plug.Cowboy.http(__MODULE__.NgrokRouter, [], ip: {127, 0, 0, 1}, port: 4040, ref: ref) do
      {:ok, _pid} ->
        on_exit(fn ->
          current_state = :sys.get_state(manager)

          if is_port(current_state.ngrok_port_handle) do
            try do
              Port.close(current_state.ngrok_port_handle)
            rescue
              _ -> :ok
            end
          end

          :sys.replace_state(manager, fn _ -> original_manager end)
          :sys.replace_state(orchestrator, fn _ -> original_orchestrator end)
          :sys.replace_state(broker, fn _ -> original_broker end)
          System.put_env("PATH", original_path)
          Plug.Cowboy.shutdown(ref)
          File.rm_rf!(root)
        end)

        :sys.replace_state(orchestrator, fn state ->
          config =
            %{state.config |
              github_webhook_provider: "ngrok",
              github_webhook_auto_register: true,
              linear_webhook_auto_register: false,
              github_webhook_secret: "secret"}

          %{state | config: config}
        end)

        :sys.replace_state(broker, fn state ->
          %{state |
            owner: true,
            session_id: "session-1",
            sessions: %{
              "session-1" => %{session_id: "session-1", repo: "acme/repo", project_slug: nil}
            }}
        end)

        :sys.replace_state(manager, fn _ ->
          %{original_manager | public_url: nil, github_webhooks: %{}, linear_webhooks: %{}, last_error: nil}
        end)

        send(manager, :ensure_ready)
        _current =
          wait_for_current(fn current ->
            current.public_url == "https://example.ngrok.app" and
              current.github_webhooks["acme/repo"] != nil
          end)

        payload = Jason.decode!(File.read!(payload_log))
        assert Enum.sort(payload["events"]) ==
                 Enum.sort(["pull_request", "pull_request_review", "issue_comment", "pull_request_review_comment"])

      {:error, :eaddrinuse} ->
        System.put_env("PATH", original_path)
        File.rm_rf!(root)
        assert true
    end
  end

  test "ensure_ready records ngrok installation failures" do
    manager = Process.whereis(Symphony.GitHubWebhookManager)
    orchestrator = Process.whereis(Symphony.Orchestrator)
    broker = Process.whereis(Symphony.Broker)
    original_manager = :sys.get_state(manager)
    original_orchestrator = :sys.get_state(orchestrator)
    original_broker = :sys.get_state(broker)
    original_path = System.get_env("PATH") || ""
    empty_bin = Path.join(System.tmp_dir!(), "symphony-ghwm-empty-#{System.unique_integer([:positive])}")
    File.mkdir_p!(empty_bin)
    System.put_env("PATH", empty_bin)

    on_exit(fn ->
      :sys.replace_state(manager, fn _ -> original_manager end)
      :sys.replace_state(orchestrator, fn _ -> original_orchestrator end)
      :sys.replace_state(broker, fn _ -> original_broker end)
      System.put_env("PATH", original_path)
      File.rm_rf!(empty_bin)
    end)

    :sys.replace_state(orchestrator, fn state ->
      config =
        %{state.config |
          github_webhook_provider: "ngrok",
          github_webhook_auto_register: true,
          linear_webhook_auto_register: false,
          github_webhook_secret: "secret"}

      %{state | config: config}
    end)

    :sys.replace_state(broker, fn state -> %{state | owner: true} end)
    :sys.replace_state(manager, fn _ -> %{original_manager | last_error: nil} end)

    send(manager, :ensure_ready)
    Process.sleep(100)

    assert Symphony.GitHubWebhookManager.current().last_error =~ ":ngrok_not_installed"
  end

  test "ensure_ready clears stored github hooks when auto-register is disabled" do
    manager = Process.whereis(Symphony.GitHubWebhookManager)
    orchestrator = Process.whereis(Symphony.Orchestrator)
    broker = Process.whereis(Symphony.Broker)
    original_manager = :sys.get_state(manager)
    original_orchestrator = :sys.get_state(orchestrator)
    original_broker = :sys.get_state(broker)

    root = Path.join(System.tmp_dir!(), "symphony-ghwm-cleanup-#{System.unique_integer([:positive])}")
    bin_dir = Path.join(root, "bin")
    File.mkdir_p!(bin_dir)
    gh_path = Path.join(bin_dir, "gh")
    deletes_path = Path.join(root, "gh_deletes.log")
    original_path = System.get_env("PATH") || ""
    ref = make_ref()

    File.write!(
      gh_path,
      """
      #!/usr/bin/env python3
      import os, sys
      args = sys.argv[1:]
      if args[:3] == ["api", "--method", "DELETE"]:
          with open(os.environ["GH_DELETES_LOG"], "a", encoding="utf-8") as fh:
              fh.write(args[3] + "\\n")
      print("{}" if args[:2] == ["api", "repos/acme/repo/hooks"] else "", end="")
      """
    )

    File.chmod!(gh_path, 0o755)
    System.put_env("PATH", bin_dir <> ":" <> original_path)
    System.put_env("GH_DELETES_LOG", deletes_path)

    case Plug.Cowboy.http(__MODULE__.NgrokRouter, [], ip: {127, 0, 0, 1}, port: 4040, ref: ref) do
      {:ok, _pid} ->
        on_exit(fn ->
          :sys.replace_state(manager, fn _ -> original_manager end)
          :sys.replace_state(orchestrator, fn _ -> original_orchestrator end)
          :sys.replace_state(broker, fn _ -> original_broker end)
          System.put_env("PATH", original_path)
          System.delete_env("GH_DELETES_LOG")
          Plug.Cowboy.shutdown(ref)
          File.rm_rf!(root)
        end)

        :sys.replace_state(orchestrator, fn state ->
          %{state | config: %{state.config | tracker_kind: "mock", github_webhook_provider: "ngrok", github_webhook_auto_register: false, linear_webhook_auto_register: true}}
        end)

        :sys.replace_state(broker, fn state -> %{state | owner: true, sessions: %{}} end)

        :sys.replace_state(manager, fn _ ->
          %{original_manager | github_webhooks: %{"acme/repo" => %{id: 321, repo: "acme/repo", callback: "https://old.ngrok/github/webhook"}}}
        end)

        send(manager, :ensure_ready)
        current = wait_for_current(fn current -> current.github_webhooks == %{} end)

        assert current.github_webhooks == %{}
        assert File.read!(deletes_path) =~ "repos/acme/repo/hooks/321"

      {:error, :eaddrinuse} ->
        System.put_env("PATH", original_path)
        System.delete_env("GH_DELETES_LOG")
        File.rm_rf!(root)
        assert true
    end
  end

  test "ensure_ready keeps matching github hooks without recreating them" do
    manager = Process.whereis(Symphony.GitHubWebhookManager)
    orchestrator = Process.whereis(Symphony.Orchestrator)
    broker = Process.whereis(Symphony.Broker)
    original_manager = :sys.get_state(manager)
    original_orchestrator = :sys.get_state(orchestrator)
    original_broker = :sys.get_state(broker)

    root = Path.join(System.tmp_dir!(), "symphony-ghwm-reuse-#{System.unique_integer([:positive])}")
    bin_dir = Path.join(root, "bin")
    File.mkdir_p!(bin_dir)

    ngrok_path = Path.join(bin_dir, "ngrok")
    gh_path = Path.join(bin_dir, "gh")
    gh_log = Path.join(root, "gh.log")
    original_path = System.get_env("PATH") || ""
    ref = make_ref()

    File.write!(ngrok_path, "#!/bin/bash\nsleep 30\n")

    File.write!(
      gh_path,
      """
      #!/usr/bin/env python3
      import os, sys
      with open(os.environ["GH_CALL_LOG"], "a", encoding="utf-8") as fh:
          fh.write(" ".join(sys.argv[1:]) + "\\n")
      print("[]", end="")
      """
    )

    File.chmod!(ngrok_path, 0o755)
    File.chmod!(gh_path, 0o755)
    System.put_env("PATH", bin_dir <> ":" <> original_path)
    System.put_env("GH_CALL_LOG", gh_log)

    case Plug.Cowboy.http(__MODULE__.NgrokRouter, [], ip: {127, 0, 0, 1}, port: 4040, ref: ref) do
      {:ok, _pid} ->
        on_exit(fn ->
          current_state = :sys.get_state(manager)

          if is_port(current_state.ngrok_port_handle) do
            try do
              Port.close(current_state.ngrok_port_handle)
            rescue
              _ -> :ok
            end
          end

          :sys.replace_state(manager, fn _ -> original_manager end)
          :sys.replace_state(orchestrator, fn _ -> original_orchestrator end)
          :sys.replace_state(broker, fn _ -> original_broker end)
          System.put_env("PATH", original_path)
          System.delete_env("GH_CALL_LOG")
          Plug.Cowboy.shutdown(ref)
          File.rm_rf!(root)
        end)

        :sys.replace_state(orchestrator, fn state ->
          config =
            %{state.config |
              github_webhook_provider: "ngrok",
              github_webhook_auto_register: true,
              linear_webhook_auto_register: false,
              github_webhook_secret: "secret"}

          %{state | config: config}
        end)

        :sys.replace_state(broker, fn state ->
          %{state |
            owner: true,
            session_id: "session-1",
            sessions: %{"session-1" => %{session_id: "session-1", repo: "acme/repo", project_slug: nil}}}
        end)

        :sys.replace_state(manager, fn _ ->
          %{original_manager | public_url: nil, github_webhooks: %{"acme/repo" => %{id: 123, repo: "acme/repo", callback: "https://example.ngrok.app/github/webhook"}}, linear_webhooks: %{}, last_error: nil}
        end)

        send(manager, :ensure_ready)
        current =
          wait_for_current(fn current ->
            current.public_url == "https://example.ngrok.app" and current.github_webhooks["acme/repo"] != nil
          end)

        assert current.github_webhooks["acme/repo"] == %{id: 123, repo: "acme/repo", callback: "https://example.ngrok.app/github/webhook"}
        refute File.exists?(gh_log)

      {:error, :eaddrinuse} ->
        System.put_env("PATH", original_path)
        System.delete_env("GH_CALL_LOG")
        File.rm_rf!(root)
        assert true
    end
  end

  test "ensure_ready clears stored linear hooks when auto-register is disabled" do
    manager = Process.whereis(Symphony.GitHubWebhookManager)
    orchestrator = Process.whereis(Symphony.Orchestrator)
    broker = Process.whereis(Symphony.Broker)
    original_manager = :sys.get_state(manager)
    original_orchestrator = :sys.get_state(orchestrator)
    original_broker = :sys.get_state(broker)
    root = Path.join(System.tmp_dir!(), "symphony-ghwm-linear-cleanup-#{System.unique_integer([:positive])}")
    bin_dir = Path.join(root, "bin")
    File.mkdir_p!(bin_dir)
    gh_path = Path.join(bin_dir, "gh")
    original_path = System.get_env("PATH") || ""
    ref = make_ref()

    File.write!(gh_path, "#!/usr/bin/env python3\nprint('[]', end='')\n")
    File.chmod!(gh_path, 0o755)
    System.put_env("PATH", bin_dir <> ":" <> original_path)

    case Plug.Cowboy.http(__MODULE__.NgrokRouter, [], ip: {127, 0, 0, 1}, port: 4040, ref: ref) do
      {:ok, _pid} ->
        on_exit(fn ->
          :sys.replace_state(manager, fn _ -> original_manager end)
          :sys.replace_state(orchestrator, fn _ -> original_orchestrator end)
          :sys.replace_state(broker, fn _ -> original_broker end)
          System.put_env("PATH", original_path)
          Plug.Cowboy.shutdown(ref)
          File.rm_rf!(root)
        end)

        :sys.replace_state(orchestrator, fn state ->
          %{state | config: %{state.config | tracker_kind: "mock", github_webhook_provider: "ngrok", github_webhook_auto_register: true, linear_webhook_auto_register: false}}
        end)

        :sys.replace_state(broker, fn state -> %{state | owner: true, sessions: %{}} end)

        :sys.replace_state(manager, fn _ ->
          %{original_manager | linear_webhooks: %{"proj-1" => %{id: "mock-linear-webhook", project_slug: "proj-1", callback: "https://old.ngrok/linear/webhook/proj-1"}}}
        end)

        send(manager, :ensure_ready)
        current = wait_for_current(fn current -> current.linear_webhooks == %{} end)
        assert current.linear_webhooks == %{}

      {:error, :eaddrinuse} ->
        System.put_env("PATH", original_path)
        File.rm_rf!(root)
        assert true
    end
  end

  defmodule NgrokRouter do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/api/tunnels" do
      body = Jason.encode!(%{"tunnels" => [%{"public_url" => "https://example.ngrok.app"}]})
      Conn.send_resp(conn, 200, body)
    end
  end

  defp wait_for_current(predicate, attempts \\ 20)

  defp wait_for_current(predicate, attempts) when attempts > 0 do
    current = Symphony.GitHubWebhookManager.current()

    if predicate.(current) do
      current
    else
      Process.sleep(25)
      wait_for_current(predicate, attempts - 1)
    end
  end

  defp wait_for_current(_predicate, 0), do: Symphony.GitHubWebhookManager.current()
end
