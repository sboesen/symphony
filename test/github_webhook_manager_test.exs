defmodule Symphony.GitHubWebhookManagerTest do
  use ExUnit.Case, async: false

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
end
