defmodule Symphony.CLIRuntime do
  @moduledoc false

  def persist_runtime_context(parsed, workflow_path, runtime_file \\ System.get_env("SYMPHONY_RUNTIME_FILE")) do
    case normalize_value(runtime_file) do
      nil ->
        :ok

      path ->
        body =
          Jason.encode!(%{
            workflow_path: workflow_path,
            project_slug: parsed.project_slug,
            repo_url: parsed.repo_url
          })

        File.write(path, body)
    end
  end

  def project_lock_path(project_slug) when is_binary(project_slug) and project_slug != "" do
    Path.join(System.tmp_dir!(), "symphony-project-#{project_slug}.lock")
  end

  def project_lock_path(_), do: nil

  def acquire_project_lock(path, pid \\ os_pid(), alive_fun \\ &pid_alive?/1)

  def acquire_project_lock(nil, _pid, _alive_fun), do: :ok

  def acquire_project_lock(path, pid, alive_fun) do
    case File.read(path) do
      {:ok, body} ->
        case Integer.parse(String.trim(body)) do
          {existing_pid, ""} when existing_pid > 0 ->
            if alive_fun.(existing_pid) do
              {:error, {:already_running, existing_pid}}
            else
              write_project_lock(path, pid)
            end

          _ ->
            write_project_lock(path, pid)
        end

      _ ->
        write_project_lock(path, pid)
    end
  end

  def release_project_lock(path, pid \\ os_pid_int())

  def release_project_lock(nil, _pid), do: :ok

  def release_project_lock(path, pid) do
    case File.read(path) do
      {:ok, body} ->
        case Integer.parse(String.trim(body)) do
          {file_pid, ""} when file_pid == pid ->
            File.rm(path)
            :ok

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  def force_release_project_lock(nil), do: :ok

  def force_release_project_lock(path) do
    File.rm(path)
    :ok
  end

  def pid_alive?(pid) when is_integer(pid) and pid > 0 do
    case System.cmd("bash", ["--noprofile", "--norc", "-c", "kill -0 #{pid} 2>/dev/null"]) do
      {_out, 0} -> true
      _ -> false
    end
  end

  def pid_alive?(_), do: false

  def os_pid do
    :os.getpid() |> List.to_string()
  end

  def os_pid_int do
    os_pid()
    |> Integer.parse()
    |> case do
      {pid, ""} -> pid
      _ -> -1
    end
  end

  defp write_project_lock(path, pid) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, pid)
    :ok
  end

  defp normalize_value(nil), do: nil

  defp normalize_value(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end
end
