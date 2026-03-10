defmodule Symphony.StatusServerTest do
  use ExUnit.Case, async: false

  test "ensure_started validates nil and invalid ports" do
    assert {:ok, nil} = Symphony.StatusServer.ensure_started(nil)
    assert {:error, :invalid_server_port} = Symphony.StatusServer.ensure_started(-1)
    assert {:error, :invalid_server_port} = Symphony.StatusServer.ensure_started("4000")
  end

  test "ensure_started binds and can fall back when the requested port is occupied" do
    {:ok, free_socket} = :gen_tcp.listen(0, [:binary, {:packet, 0}, {:active, false}])
    {:ok, requested} = :inet.port(free_socket)
    :gen_tcp.close(free_socket)

    assert {:ok, first_port} = Symphony.StatusServer.ensure_started(requested)
    assert is_integer(first_port)
    assert first_port > 0

    {:ok, socket} = :gen_tcp.listen(0, [:binary, {:packet, 0}, {:active, false}])
    {:ok, occupied_port} = :inet.port(socket)

    assert {:ok, rebound_port} = Symphony.StatusServer.ensure_started(occupied_port)
    assert is_integer(rebound_port)
    assert rebound_port > 0
    refute rebound_port == occupied_port

    :gen_tcp.close(socket)

    assert {:ok, same_port} = Symphony.StatusServer.ensure_started(rebound_port)
    assert same_port == rebound_port
  end
end
