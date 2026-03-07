defmodule Symphony.Shell do
  @moduledoc "Runs workflow hook scripts in workspace context with timeout."

  @managed_tmp_dir ".symphony/tmp"

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

  def start_managed_script(nil, _cwd, _timeout_ms), do: {:ok, nil}

  def start_managed_script(script, cwd, timeout_ms)
      when is_binary(script) and byte_size(script) > 0 do
    timeout = max(100, timeout_ms)

    with {:ok, tmp_dir} <- ensure_managed_tmp_dir(cwd),
         {:ok, script_path} <- write_managed_script(tmp_dir, script),
         {:ok, log_path} <- managed_log_path(tmp_dir),
         {:ok, pid} <- spawn_managed_script(script_path, log_path, cwd, timeout) do
      {:ok, %{pid: pid, log_path: log_path, script_path: script_path}}
    end
  end

  def start_managed_script(_, _, _), do: {:ok, nil}

  def stop_managed_script(nil, _timeout_ms), do: :ok

  def stop_managed_script(%{pid: pid} = handle, timeout_ms) when is_integer(pid) and pid > 0 do
    timeout = max(100, timeout_ms)

    result =
      case System.cmd("bash", ["--noprofile", "--norc", "-c", stop_script(pid)],
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        {out, status} -> {:error, {:exit_status, status, String.trim(out)}}
      end

    _ = cleanup_managed_script(handle)

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        case wait_for_exit(pid, timeout) do
          :ok -> :ok
          {:error, _} -> {:error, reason}
        end
    end
  end

  def stop_managed_script(_, _timeout_ms), do: :ok

  def truncate(value, max) when is_binary(value) and byte_size(value) > max, do: String.slice(value, 0, max)
  def truncate(value, _), do: value

  defp ensure_managed_tmp_dir(cwd) do
    dir = Path.join(cwd, @managed_tmp_dir)

    case File.mkdir_p(dir) do
      :ok -> {:ok, dir}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_managed_script(tmp_dir, script) do
    script_path = Path.join(tmp_dir, "managed-#{System.unique_integer([:positive])}.sh")
    content = "#!/usr/bin/env bash\nset -eo pipefail\n#{script}\n"

    case File.write(script_path, content) do
      :ok ->
        case File.chmod(script_path, 0o755) do
          :ok -> {:ok, script_path}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp managed_log_path(tmp_dir) do
    {:ok, Path.join(tmp_dir, "managed-#{System.unique_integer([:positive])}.log")}
  end

  defp spawn_managed_script(script_path, log_path, cwd, timeout_ms) do
    command =
      [
        "set -eo pipefail",
        "script_path=#{shell_escape(script_path)}",
        "log_path=#{shell_escape(log_path)}",
        "cd #{shell_escape(cwd)}",
        "if command -v setsid >/dev/null 2>&1; then",
        "  setsid \"$script_path\" >\"$log_path\" 2>&1 < /dev/null &",
        "else",
        "  nohup \"$script_path\" >\"$log_path\" 2>&1 < /dev/null &",
        "fi",
        "echo $!"
      ]
      |> Enum.join("\n")

    task =
      Task.async(fn ->
        System.cmd("bash", ["--noprofile", "--norc", "-c", command], stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, 0}} ->
        parse_managed_pid(out)

      {:ok, {out, status}} ->
        {:error, {:exit_status, status, String.trim(out)}}

      _ ->
        {:error, :timeout}
    end
  end

  defp parse_managed_pid(output) do
    output
    |> String.split("\n", trim: true)
    |> List.last()
    |> case do
      nil ->
        {:error, :managed_pid_missing}

      value ->
        case Integer.parse(String.trim(value)) do
          {pid, ""} when pid > 0 -> {:ok, pid}
          _ -> {:error, {:managed_pid_invalid, value}}
        end
    end
  end

  defp stop_script(pid) do
    """
    pid=#{pid}
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      if kill -0 "$pid" 2>/dev/null; then
        kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
      fi
    fi
    """
  end

  defp wait_for_exit(pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_exit(pid, deadline)
  end

  defp do_wait_for_exit(pid, deadline_ms) do
    cond do
      not pid_alive?(pid) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline_ms ->
        {:error, :timeout}

      true ->
        Process.sleep(100)
        do_wait_for_exit(pid, deadline_ms)
    end
  end

  defp pid_alive?(pid) do
    case System.cmd("bash", ["--noprofile", "--norc", "-c", "kill -0 #{pid} 2>/dev/null"],
           stderr_to_stdout: true
         ) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp cleanup_managed_script(%{script_path: script_path}) when is_binary(script_path) do
    _ = File.rm(script_path)
    :ok
  end

  defp cleanup_managed_script(_), do: :ok

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end
end
