defmodule Symphony.StatusServer do
  @moduledoc "Starts and (re)binds the optional status HTTP server."

  use GenServer

  require Logger

  @cowboy_ref __MODULE__.HTTP

  def ensure_started(nil), do: :ok
  def ensure_started(port) when not is_integer(port) or port <= 0, do: {:error, :invalid_server_port}

  def ensure_started(port) do
    case Process.whereis(__MODULE__) do
      nil ->
        case GenServer.start_link(__MODULE__, port, name: __MODULE__) do
          {:ok, _pid} -> :ok
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
    {:noreply, ensure_port(state, port)}
  end

  @impl true
  def handle_call({:ensure_port, port}, _from, state) do
    next_state = ensure_port(state, port)
    {:reply, :ok, next_state}
  end

  defp ensure_port(state, port) when state.port == port, do: state

  defp ensure_port(state, port) do
    if is_integer(state.port) and state.port > 0 do
      _ = Plug.Cowboy.shutdown(@cowboy_ref)
    end

    case Plug.Cowboy.http(Symphony.StatusRouter, [], port: port, ref: @cowboy_ref) do
      {:ok, _pid} ->
        Logger.info("status server listening on port #{port}")
        %{state | port: port}

      {:error, {:already_started, _pid}} ->
        %{state | port: port}

      {:error, reason} ->
        Logger.error("failed to start status server on port #{port}: #{inspect(reason)}")
        state
    end
  end
end
