defmodule Symphony.ArtifactRecorder do
  @moduledoc "Captures optional per-issue validation artifacts through an external Playwright script."

  require Logger

  alias Symphony.TemplateRenderer

  @default_output_dir ".symphony/artifacts/recordings"
  @manifest_filename "manifest.json"
  @demo_plan_rel_path ".git/symphony/demo-plan.json"
  @capture_retry_attempts 3
  @capture_retry_backoff_ms 1_000

  @spec capture(struct(), integer() | nil, Path.t(), Symphony.Config.t()) ::
          {:ok, [map()]} | {:error, term(), [map()]}
  def capture(issue, attempt, workspace_path, config) do
    if recording_disabled?(config) do
      {:ok, []}
    else
      with {:ok, target_url} <- render_required(config.recording_url, issue, attempt),
           {:ok, ready_url} <- render_optional(config.recording_ready_url, issue, attempt),
           {:ok, setup_command} <- render_optional(config.recording_setup_command, issue, attempt),
           {:ok, teardown_command} <-
             render_optional(config.recording_teardown_command, issue, attempt),
           {:ok, wait_for_selector} <-
             render_optional(config.recording_wait_for_selector, issue, attempt),
           {:ok, wait_for_text} <- render_optional(config.recording_wait_for_text, issue, attempt),
           {:ok, recording_output_dir} <-
             render_optional(config.recording_output_dir, issue, attempt),
           {:ok, output_dir} <- ensure_output_dir(workspace_path, recording_output_dir) do
        demo_plan_path = existing_demo_plan_path(workspace_path)
        demo_plan = load_demo_plan_map(demo_plan_path)
        normalized_url =
          target_url
          |> normalize_target_url(workspace_path)
          |> normalize_loopback_url()

        effective_capture_url =
          demo_plan
          |> plan_string("url")
          |> Kernel.||(target_url)
          |> normalize_target_url(workspace_path)
          |> normalize_loopback_url()

        effective_ready_url =
          plan_string(demo_plan, "ready_url") ||
            plan_string(demo_plan, "url") ||
            ready_url

        normalized_ready_url =
          normalize_ready_url(effective_ready_url, normalized_url, workspace_path)
          |> normalize_loopback_url()

        effective_setup_command =
          demo_plan
          |> plan_string("setup_command")
          |> Kernel.||(setup_command)
          |> enforce_local_strict_port(normalized_ready_url)

        {normalized_ready_url, effective_capture_url, effective_setup_command} =
          maybe_rebind_local_demo_target(
            normalized_ready_url,
            effective_capture_url,
            effective_setup_command
          )

        effective_teardown_command =
          plan_string(demo_plan, "teardown_command") || teardown_command

        case ensure_local_demo_setup(normalized_ready_url, effective_setup_command) do
          :ok ->
            _ = maybe_release_local_port(normalized_ready_url)
            case maybe_install_js_dependencies(workspace_path, effective_setup_command) do
              :ok ->
                setup_result =
                  case maybe_start_managed_command(
                         effective_setup_command,
                         workspace_path,
                         config.hooks_timeout_ms,
                         :setup
                       ) do
                    {:ok, handle} -> {:ok, handle}
                    {:error, reason} -> {:error, {:recording_setup_failed, reason}, []}
                  end

                case setup_result do
                  {:ok, setup_handle} ->
                    Logger.info(
                      "recording capture setup started for #{issue.identifier} in #{workspace_path} " <>
                        "(setup_command=#{inspect(log_value(effective_setup_command))}, " <>
                        "ready_url=#{inspect(log_value(normalized_ready_url))}, " <>
                        "capture_url=#{inspect(log_value(effective_capture_url))}, " <>
                        "demo_plan_path=#{inspect(log_value(demo_plan_path))})"
                    )

                    capture_result =
                      try do
                        with :ok <-
                               wait_until_ready(normalized_ready_url, config.recording_ready_timeout_ms),
                             _ <- Logger.info("recording target ready for #{issue.identifier}: #{normalized_ready_url}"),
                             _ <-
                               Logger.info(
                                 "recording capture beginning for #{issue.identifier}: " <>
                                   "capture_url=#{inspect(log_value(effective_capture_url))}, " <>
                                   "wait_for_selector=#{inspect(log_value(wait_for_selector))}, " <>
                                   "wait_for_text=#{inspect(log_value(wait_for_text))}"
                               ),
                             {:ok, artifact} <-
                               capture_with_retry(
                                 effective_capture_url,
                                 wait_for_selector,
                                 wait_for_text,
                                 demo_plan_path,
                                 output_dir,
                                 config,
                                 @capture_retry_attempts
                               ) do
                          {:ok, [artifact]}
                        else
                          {:error, reason, artifact} ->
                            failure_artifact =
                              artifact || failed_artifact(effective_capture_url, output_dir, reason)
                            {:error, reason, [failure_artifact]}

                          {:error, reason} ->
                            failure_artifact = failed_artifact(effective_capture_url, output_dir, reason)
                            {:error, reason, [failure_artifact]}
                        end
                      after
                        _ = Symphony.Shell.stop_managed_script(setup_handle, config.hooks_timeout_ms)
                        Logger.info("recording setup stopped for #{issue.identifier}")

                        _ =
                          maybe_run_command(
                            effective_teardown_command,
                            workspace_path,
                            config.hooks_timeout_ms,
                            :teardown
                          )
                      end

                    case capture_result do
                      {:ok, artifacts} ->
                        {:ok, artifacts}

                      {:error, reason, artifacts} ->
                        {:error, {:recording_capture_failed, reason}, artifacts}
                    end

                  {:error, _reason, _artifacts} = error ->
                    error
                end

              {:error, reason} ->
                {:error, {:recording_setup_failed, reason}, []}
            end

          {:error, reason} ->
            {:error, reason, []}
        end
      end
    end
  end

  defp recording_disabled?(config) do
    not config.recording_enabled or is_nil(config.recording_url) or
      String.trim(config.recording_url) == ""
  end

  defp log_value(nil), do: nil

  defp log_value(value) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp log_value(value), do: value

  defp render_required(value, issue, attempt) when is_binary(value) do
    case TemplateRenderer.render(value, issue, attempt) do
      {:ok, rendered} ->
        trimmed = String.trim(rendered)
        if trimmed == "", do: {:error, :recording_url_missing}, else: {:ok, trimmed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp render_required(_, _issue, _attempt), do: {:error, :recording_url_missing}

  defp render_optional(nil, _issue, _attempt), do: {:ok, nil}

  defp render_optional(value, issue, attempt) when is_binary(value) do
    case TemplateRenderer.render(value, issue, attempt) do
      {:ok, rendered} ->
        trimmed = String.trim(rendered)
        if trimmed == "", do: {:ok, nil}, else: {:ok, trimmed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp render_optional(_, _issue, _attempt), do: {:ok, nil}

  defp ensure_output_dir(workspace_path, configured_dir) do
    base_dir =
      case configured_dir do
        value when is_binary(value) and value != "" ->
          if Path.type(value) == :absolute do
            value
          else
            Path.join(workspace_path, value)
          end

        _ ->
          Path.join(workspace_path, @default_output_dir)
      end

    timestamp = System.system_time(:millisecond)
    output_dir = Path.join(base_dir, "capture-#{timestamp}")

    case File.mkdir_p(output_dir) do
      :ok -> {:ok, Path.expand(output_dir)}
      {:error, reason} -> {:error, {:recording_output_dir_failed, reason}}
    end
  end

  defp normalize_target_url(value, workspace_path) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme} when scheme in ["http", "https", "file"] ->
        value

      _ ->
        path =
          if Path.type(value) == :absolute do
            value
          else
            Path.expand(value, workspace_path)
          end

        "file://" <> path
    end
  end

  defp normalize_ready_url(nil, normalized_target_url, _workspace_path), do: normalized_target_url

  defp normalize_ready_url(value, _normalized_target_url, workspace_path) do
    normalize_target_url(value, workspace_path)
  end

  defp normalize_loopback_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and host in ["127.0.0.1", "::1"] ->
        %{uri | host: "localhost"} |> URI.to_string()

      _ ->
        url
    end
  end

  defp normalize_loopback_url(url), do: url

  defp maybe_run_command(nil, _workspace_path, _timeout_ms, _stage), do: :ok

  defp maybe_run_command(command, workspace_path, timeout_ms, stage) do
    case Symphony.Shell.run_script(command, workspace_path, timeout_ms) do
      {:ok, _output} ->
        :ok

      {:error, reason} ->
        Logger.warning("recording #{stage} command failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp maybe_start_managed_command(nil, _workspace_path, _timeout_ms, _stage), do: {:ok, nil}

  defp maybe_start_managed_command(command, workspace_path, timeout_ms, stage) do
    case Symphony.Shell.start_managed_script(command, workspace_path, timeout_ms) do
      {:ok, handle} ->
        {:ok, handle}

      {:error, reason} ->
        Logger.warning("recording #{stage} command failed to start: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp maybe_release_local_port(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and host in ["127.0.0.1", "localhost"] and
             is_integer(port) ->
        _ =
          System.cmd(
            "bash",
            [
              "--noprofile",
              "--norc",
              "-c",
              "pids=$(lsof -ti tcp:#{port} 2>/dev/null || true); if [ -n \"$pids\" ]; then kill -TERM $pids 2>/dev/null || true; sleep 1; pids=$(lsof -ti tcp:#{port} 2>/dev/null || true); if [ -n \"$pids\" ]; then kill -KILL $pids 2>/dev/null || true; fi; fi"
            ],
            stderr_to_stdout: true
          )

        :ok

      _ ->
        :ok
    end
  end

  defp maybe_release_local_port(_), do: :ok

  defp maybe_rebind_local_demo_target(ready_url, capture_url, setup_command) do
    case local_ready_target(ready_url) do
      {:ok, host, port} ->
        if local_port_occupied?(port) do
          replacement_port = find_free_local_port()

          {
            replace_url_port(ready_url, replacement_port),
            replace_url_port(capture_url, replacement_port),
            replace_command_port(setup_command, host, replacement_port)
          }
        else
          {ready_url, capture_url, setup_command}
        end

      :error ->
        {ready_url, capture_url, setup_command}
    end
  end

  defp enforce_local_strict_port(nil, _ready_url), do: nil

  defp enforce_local_strict_port(command, ready_url) when is_binary(command) do
    case local_ready_target(ready_url) do
      {:ok, host, port} ->
        trimmed = String.trim(command)

        cond do
          trimmed == "" ->
            nil

          String.contains?(trimmed, "--strictPort") ->
            trimmed

          package_runner_command?(trimmed) and String.contains?(trimmed, "--port") ->
            trimmed <> " --strictPort"

          package_runner_command?(trimmed) ->
            trimmed <> " --host #{host} --port #{port} --strictPort"

          direct_dev_server_command?(trimmed) and String.contains?(trimmed, "--port") ->
            trimmed <> " --strictPort"

          direct_dev_server_command?(trimmed) ->
            trimmed <> " --host #{host} --port #{port} --strictPort"

          true ->
            trimmed
        end

      :error ->
        String.trim(command)
    end
  end

  defp local_ready_target(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and host in ["127.0.0.1", "localhost"] and
             is_integer(port) ->
        {:ok, host, port}

      _ ->
        :error
    end
  end

  defp local_port_occupied?(port) when is_integer(port) do
    case System.cmd("bash", ["--noprofile", "--norc", "-c", "lsof -ti tcp:#{port} 2>/dev/null || true"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(output) != ""
      {output, _} -> String.trim(output) != ""
    end
  end

  defp find_free_local_port do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, {:packet, 0}, {:active, false}, {:ip, {127, 0, 0, 1}}])

    {:ok, {_addr, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end

  defp replace_url_port(nil, _port), do: nil

  defp replace_url_port(url, port) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri when scheme in ["http", "https"] and is_binary(host) ->
        %{uri | port: port} |> URI.to_string()

      _ ->
        url
    end
  end

  defp replace_command_port(nil, _host, _port), do: nil

  defp replace_command_port(command, host, port) when is_binary(command) do
    command
    |> String.replace(~r/--port\s+\d+/, "--port #{port}")
    |> ensure_host_argument(host)
  end

  defp ensure_host_argument(command, host) when is_binary(command) and is_binary(host) do
    cond do
      String.match?(command, ~r/--host\s+--port/) ->
        String.replace(command, "--host --port", "--host #{host} --port")

      String.match?(command, ~r/--host\s*$/) ->
        command <> " #{host}"

      String.match?(command, ~r/--host\s+\S+/) ->
        command

      package_runner_command?(command) ->
        command <> " --host #{host}"

      direct_dev_server_command?(command) ->
        command <> " --host #{host}"

      true ->
        command
    end
  end

  defp package_runner_command?(command) do
    String.match?(command, ~r/\b(?:npm|pnpm|yarn|bun)\s+run\s+\S+/)
  end

  defp direct_dev_server_command?(command) do
    String.contains?(command, "astro dev") or
      String.contains?(command, "vite") or
      String.contains?(command, "next dev")
  end

  defp wait_until_ready(url, timeout_ms) when is_binary(url) do
    deadline = System.monotonic_time(:millisecond) + max(1_000, timeout_ms)
    do_wait_until_ready(url, deadline)
  end

  defp do_wait_until_ready(url, deadline_ms) do
    if System.monotonic_time(:millisecond) >= deadline_ms do
      {:error, :recording_ready_timeout}
    else
      case ready?(url) do
        true ->
          :ok

        false ->
          Process.sleep(250)
          do_wait_until_ready(url, deadline_ms)
      end
    end
  end

  defp ready?(url) do
    case URI.parse(url) do
      %URI{scheme: "file", path: path} when is_binary(path) ->
        File.exists?(URI.decode(path))

      %URI{scheme: scheme} = uri when scheme in ["http", "https"] ->
        uri
        |> URI.to_string()
        |> http_ready?()

      _ ->
        false
    end
  end

  defp http_ready?(url) do
    request = Finch.build(:get, url)

    case Finch.request(request, Symphony.Finch, receive_timeout: 2_000) do
      {:ok, %Finch.Response{status: status}} when status in 200..399 -> true
      _ -> false
    end
  end

  defp run_playwright_capture(
         url,
         wait_for_selector,
         wait_for_text,
         demo_plan_path,
         output_dir,
         config
       ) do
    script_path = Path.expand("scripts/record_issue_video.mjs", File.cwd!())

    args =
      [
        script_path,
        "--url",
        url,
        "--output-dir",
        output_dir,
        "--settle-ms",
        Integer.to_string(config.recording_wait_ms),
        "--width",
        Integer.to_string(config.recording_width),
        "--height",
        Integer.to_string(config.recording_height),
        "--trace",
        if(config.recording_trace, do: "true", else: "false")
      ]
      |> maybe_append("--wait-for-selector", wait_for_selector)
      |> maybe_append("--wait-for-text", wait_for_text)
      |> maybe_append("--plan-file", demo_plan_path)

    timeout_ms =
      max(
        10_000,
        config.recording_ready_timeout_ms + config.recording_wait_ms + config.hooks_timeout_ms
      )

    task =
      Task.async(fn ->
        System.cmd("node", args, stderr_to_stdout: true)
      end)

    Logger.info("starting Playwright capture for #{url} into #{output_dir}")

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_output, 0}} ->
        Logger.info("Playwright capture finished successfully for #{url}")
        read_manifest(output_dir)

      {:ok, {output, status}} ->
        Logger.warning("Playwright capture failed for #{url} with status #{status}")
        case read_manifest(output_dir) do
          {:ok, artifact} ->
            {:error, {:recording_command_failed, status, String.trim(output)}, artifact}

          _ ->
            {:error, {:recording_command_failed, status, String.trim(output)}}
        end

      nil ->
        Logger.warning("Playwright capture timed out for #{url}")
        {:error, :recording_command_timeout}
    end
  rescue
    error ->
      {:error, {:recording_command_exception, Exception.message(error)}}
  end

  defp capture_with_retry(url, wait_for_selector, wait_for_text, demo_plan_path, output_dir, config, attempts_left) do
    case run_playwright_capture(
           url,
           wait_for_selector,
           wait_for_text,
           demo_plan_path,
           output_dir,
           config
         ) do
      {:ok, _artifact} = ok ->
        ok

      {:error, reason, _artifact} = error ->
        maybe_retry_capture(
          error,
          reason,
          attempts_left,
          url,
          wait_for_selector,
          wait_for_text,
          demo_plan_path,
          output_dir,
          config
        )

      {:error, reason} = error ->
        maybe_retry_capture(
          error,
          reason,
          attempts_left,
          url,
          wait_for_selector,
          wait_for_text,
          demo_plan_path,
          output_dir,
          config
        )

      error ->
        error
    end
  end

  defp maybe_retry_capture(error, reason, attempts_left, url, wait_for_selector, wait_for_text, demo_plan_path, output_dir, config) do
    if attempts_left > 1 and retryable_capture_reason?(reason) do
      Logger.warning(
        "recording capture attempt failed, retrying (remaining=#{attempts_left - 1}): #{inspect(reason)}"
      )

      Process.sleep(@capture_retry_backoff_ms)

      capture_with_retry(
        url,
        wait_for_selector,
        wait_for_text,
        demo_plan_path,
        output_dir,
        config,
        attempts_left - 1
      )
    else
      error
    end
  end

  defp retryable_capture_reason?(reason) do
    rendered = inspect(reason)

    rendered =~ "recording_command_timeout" or
      rendered =~ "recording_command_exception" or
      rendered =~ "recording_manifest_failed" or
      rendered =~ "recording_manifest_malformed" or
      rendered =~ "recording_ready_timeout"
  end

  defp read_manifest(output_dir) do
    manifest_path = Path.join(output_dir, @manifest_filename)

    with {:ok, raw} <- File.read(manifest_path),
         {:ok, decoded} <- Jason.decode(raw) do
      {:ok,
       %{
         kind: "demo_artifact",
         capture_type: decoded["capture_type"] || infer_capture_type(decoded),
         status: decoded["status"] || "ready",
         source_url: decoded["source_url"],
         output_dir: decoded["output_dir"],
         video_path: decoded["video_path"],
         raw_video_path: decoded["raw_video_path"],
         trace_path: decoded["trace_path"],
         screenshot_path: decoded["screenshot_path"],
         verification_path: decoded["verification_path"],
         demo_plan_path: decoded["demo_plan_path"],
         assertions: decoded["assertions"] || [],
         verification: decoded["verification"] || %{},
         non_demoable: decoded["non_demoable"] || false,
         non_demoable_reason: decoded["non_demoable_reason"],
         console_errors: decoded["console_errors"] || [],
         error: decoded["error"],
         captured_at: decoded["captured_at"]
       }}
    else
      {:error, reason} ->
        {:error, {:recording_manifest_failed, reason}}

      _ ->
        {:error, :recording_manifest_malformed}
    end
  end

  defp failed_artifact(url, output_dir, reason) do
    %{
      kind: "demo_artifact",
      capture_type: "video",
      status: "error",
      source_url: url,
      output_dir: output_dir,
      video_path: nil,
      raw_video_path: nil,
      trace_path: nil,
      screenshot_path: nil,
      verification_path: nil,
      assertions: [],
      verification: %{},
      non_demoable: false,
      non_demoable_reason: nil,
      console_errors: [],
      captured_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      error: inspect(reason)
    }
  end

  defp infer_capture_type(%{"video_path" => path}) when is_binary(path) and path != "", do: "video"
  defp infer_capture_type(%{"raw_video_path" => path}) when is_binary(path) and path != "", do: "video"
  defp infer_capture_type(_), do: "screenshot"

  defp existing_demo_plan_path(workspace_path) do
    path = Path.join(workspace_path, @demo_plan_rel_path)
    if File.exists?(path), do: path, else: nil
  end

  defp load_demo_plan_map(nil), do: nil

  defp load_demo_plan_map(path) when is_binary(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, decoded} <- Jason.decode(raw),
         true <- is_map(decoded) do
      decoded
    else
      _ -> nil
    end
  end

  defp plan_string(nil, _key), do: nil

  defp plan_string(plan, key) when is_map(plan) do
    case Map.get(plan, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  defp ensure_local_demo_setup(url, setup_command) do
    case URI.parse(to_string(url || "")) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and host in ["127.0.0.1", "localhost", "::1"] ->
        if is_binary(setup_command) and String.trim(setup_command) != "" do
          :ok
        else
          {:error, :recording_setup_command_missing}
        end

      _ ->
        :ok
    end
  end

  defp maybe_install_js_dependencies(workspace_path, setup_command) do
    cond do
      not is_binary(setup_command) or String.trim(setup_command) == "" ->
        :ok

      not js_setup_command?(setup_command) ->
        :ok

      not File.exists?(Path.join(workspace_path, "package.json")) ->
        :ok

      File.exists?(Path.join(workspace_path, "node_modules")) ->
        :ok

      true ->
        install_command =
          case js_package_manager(workspace_path, setup_command) do
            "pnpm" -> "pnpm install"
            "yarn" -> "yarn install"
            "bun" -> "bun install"
            _ -> "npm install"
          end

        Logger.info(
          "recording setup installing JS dependencies in #{workspace_path} " <>
            "(install_command=#{inspect(install_command)})"
        )

        case Symphony.Shell.run_script(install_command, workspace_path, 300_000) do
          {:ok, _output} -> :ok
          {:error, reason} -> {:error, {:dependency_install_failed, reason}}
        end
    end
  end

  defp js_setup_command?(command) do
    String.match?(command, ~r/\b(?:npm|pnpm|yarn|bun)\b/)
  end

  defp js_package_manager(workspace_path, setup_command) do
    cond do
      String.starts_with?(setup_command, "pnpm ") or File.exists?(Path.join(workspace_path, "pnpm-lock.yaml")) -> "pnpm"
      String.starts_with?(setup_command, "yarn ") or File.exists?(Path.join(workspace_path, "yarn.lock")) -> "yarn"
      String.starts_with?(setup_command, "bun ") or File.exists?(Path.join(workspace_path, "bun.lockb")) -> "bun"
      true -> "npm"
    end
  end

  defp maybe_append(args, _flag, nil), do: args
  defp maybe_append(args, flag, value), do: args ++ [flag, value]
end
