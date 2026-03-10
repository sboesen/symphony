defmodule Symphony.StatusServer do
  @moduledoc "Starts and (re)binds the optional status HTTP server."

  use GenServer

  require Logger

  @cowboy_ref __MODULE__.HTTP

  def ensure_started(nil), do: {:ok, nil}
  def ensure_started(port) when not is_integer(port) or port <= 0, do: {:error, :invalid_server_port}

  def ensure_started(port) do
    case Process.whereis(__MODULE__) do
      nil ->
        case GenServer.start_link(__MODULE__, port, name: __MODULE__) do
          {:ok, _pid} -> GenServer.call(__MODULE__, :current_port)
          {:error, {:already_started, _pid}} -> GenServer.call(__MODULE__, {:ensure_port, port})
          {:error, reason} -> {:error, reason}
        end

      _pid ->
        GenServer.call(__MODULE__, {:ensure_port, port})
    end
  end

  @impl true
  def init(port) do
    {:ok, %{port: nil}, {:continue, {:ensure_port, port}}}
  end

  @impl true
  def handle_continue({:ensure_port, port}, state) do
    case ensure_port(state, port) do
      {:ok, next_state} -> {:noreply, next_state}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  @impl true
  def handle_call({:ensure_port, port}, _from, state) do
    case ensure_port(state, port) do
      {:ok, next_state} -> {:reply, {:ok, next_state.port}, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:current_port, _from, state) do
    {:reply, {:ok, state.port}, state}
  end

  defp ensure_port(state, port) when state.port == port, do: {:ok, state}

  defp ensure_port(state, port) do
    if is_integer(state.port) and state.port > 0 do
      _ = Plug.Cowboy.shutdown(@cowboy_ref)
    end

    case resolve_bind_port(port) do
      {:fallback, fallback_port} ->
        Logger.warning("status server port #{port} already in use, falling back to an ephemeral port")
        bind_and_store(state, fallback_port)

      {:ok, bind_port} ->
        bind_and_store(state, bind_port)
    end
  end

  defp bind_and_store(state, port) do
    case bind_status_router(port) do
      {:ok, _pid} ->
        actual_port = listening_port(port)
        Logger.info("status server listening on port #{actual_port}")
        {:ok, %{state | port: actual_port}}

      {:error, {:already_started, _pid}} ->
        {:ok, %{state | port: port}}

      {:error, reason} ->
        Logger.error("failed to start status server on port #{port}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp bind_status_router(port) do
    Plug.Cowboy.http(Symphony.StatusRouter, [], port: port, ref: @cowboy_ref)
  end

  defp listening_port(fallback) do
    case :ranch.get_port(@cowboy_ref) do
      port when is_integer(port) and port > 0 -> port
      _ -> fallback
    end
  end

  defp resolve_bind_port(0), do: {:ok, 0}

  defp resolve_bind_port(port) do
    case port_available?(port) do
      true -> {:ok, port}
      false -> {:fallback, 0}
    end
  end

  defp port_available?(port) do
    case :gen_tcp.listen(port, [:binary, {:packet, 0}, {:active, false}]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, :eaddrinuse} ->
        false

      {:error, _reason} ->
        true
    end
  end
end
