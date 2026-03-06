defmodule Symphony.Shell do
  @moduledoc "Runs workflow hook scripts in workspace context with timeout."

  def run_script(nil, _cwd, _timeout_ms), do: {:ok, ""}

  def run_script(script, cwd, timeout_ms) when is_binary(script) and byte_size(script) > 0 do
    timeout = max(100, timeout_ms)

    task =
      Task.async(fn ->
        System.cmd("bash", ["-lc", script], cd: cwd, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, status}} when status == 0 ->
        {:ok, out}

      {:ok, {out, status}} ->
        {:error, {:exit_status, status, String.trim(out)}}

      _ ->
        {:error, :timeout}
    end
  end

  def run_script(_, _, _), do: {:ok, ""}

  def truncate(value, max) when is_binary(value) and byte_size(value) > max, do: String.slice(value, 0, max)
  def truncate(value, _), do: value
end
