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
        normalized_url = normalize_target_url(target_url, workspace_path)
        normalized_ready_url = normalize_ready_url(ready_url, normalized_url, workspace_path)

        setup_result =
          case maybe_start_managed_command(
                 setup_command,
                 workspace_path,
                 config.hooks_timeout_ms,
                 :setup
               ) do
            {:ok, handle} -> {:ok, handle}
            {:error, reason} -> {:error, {:recording_setup_failed, reason}, []}
          end

        case setup_result do
          {:ok, setup_handle} ->
            Logger.info("recording capture setup started for #{issue.identifier} in #{workspace_path}")

            capture_result =
              try do
                demo_plan_path = existing_demo_plan_path(workspace_path)

                with :ok <-
                       wait_until_ready(normalized_ready_url, config.recording_ready_timeout_ms),
                     _ <- Logger.info("recording target ready for #{issue.identifier}: #{normalized_ready_url}"),
                     {:ok, artifact} <-
                       capture_with_retry(
                         normalized_url,
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
                    failure_artifact = artifact || failed_artifact(normalized_url, output_dir, reason)
                    {:error, reason, [failure_artifact]}

                  {:error, reason} ->
                    failure_artifact = failed_artifact(normalized_url, output_dir, reason)
                    {:error, reason, [failure_artifact]}
                end
              after
               _ = Symphony.Shell.stop_managed_script(setup_handle, config.hooks_timeout_ms)
                Logger.info("recording setup stopped for #{issue.identifier}")

                _ =
                  maybe_run_command(
                    teardown_command,
                    workspace_path,
                    config.hooks_timeout_ms,
                    :teardown
                  )
              end

            case capture_result do
              {:ok, artifacts} ->
                {:ok, artifacts}

              {:error, reason, artifacts} when config.recording_strict ->
                {:error, {:recording_capture_failed, reason}, artifacts}

              {:error, _reason, artifacts} ->
                {:ok, artifacts}
            end

          {:error, _reason, _artifacts} = error ->
            error
        end
      end
    end
  end

  defp recording_disabled?(config) do
    not config.recording_enabled or is_nil(config.recording_url) or
      String.trim(config.recording_url) == ""
  end

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
         kind: "video_recording",
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
      kind: "video_recording",
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

  defp existing_demo_plan_path(workspace_path) do
    path = Path.join(workspace_path, @demo_plan_rel_path)
    if File.exists?(path), do: path, else: nil
  end

  defp maybe_append(args, _flag, nil), do: args
  defp maybe_append(args, flag, value), do: args ++ [flag, value]
end
