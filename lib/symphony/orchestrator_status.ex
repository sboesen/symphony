defmodule Symphony.OrchestratorStatus do
  @moduledoc false

  alias Symphony.Issue

  def status_payload(state) do
    %{
      workflow_path: state.workflow_path,
      poll_enabled: state.poll_enabled,
      workflow_mtime_ms: state.workflow_mtime_ms,
      poll_interval_ms: state.poll_interval_ms,
      paused: state.paused,
      paused_reason: state.paused_reason,
      paused_until_ms: state.paused_until_ms,
      running_count: map_size(state.running),
      running: summarize_running(state.running),
      retry_count: map_size(state.retry_attempts),
      retries: summarize_retries(state.retry_attempts),
      claimed_count: MapSet.size(state.claimed),
      completed_count: MapSet.size(state.completed),
      candidate_count: length(state.last_candidates),
      candidates: state.last_candidates,
      recent_runs: summarize_recent_runs(state.recent_runs),
      events: summarize_events(state.events),
      codex_totals: state.codex_totals,
      status_port: state.status_port,
      config: summarize_config(state.config)
    }
  end

  def issue_status_payload(state, issue_identifier) do
    issue_identifier = String.trim(issue_identifier)

    running_entry =
      state.running
      |> Map.values()
      |> Enum.find(&(&1.issue_identifier == issue_identifier))

    retry_entry =
      state.retry_attempts
      |> Map.values()
      |> Enum.find(&(&1.identifier == issue_identifier))

    recent_run =
      state.recent_runs
      |> Enum.find(&(&1.identifier == issue_identifier))

    cond do
      running_entry ->
        %{
          issue_identifier: issue_identifier,
          status: "running",
          running: summarize_running_entry(running_entry),
          retry: nil,
          recent_run: recent_run && summarize_recent_run(recent_run),
          events: summarize_issue_events(state.events, issue_identifier)
        }

      retry_entry ->
        %{
          issue_identifier: issue_identifier,
          status: "retrying",
          running: nil,
          retry: summarize_retry_entry(retry_entry),
          recent_run: recent_run && summarize_recent_run(recent_run),
          events: summarize_issue_events(state.events, issue_identifier)
        }

      recent_run ->
        %{
          issue_identifier: issue_identifier,
          status: recent_run.outcome,
          running: nil,
          retry: nil,
          recent_run: summarize_recent_run(recent_run),
          events: summarize_issue_events(state.events, issue_identifier)
        }

      true ->
        nil
    end
  end

  def pending_review_artifact(run) when is_map(run) do
    run.artifacts
    |> List.wrap()
    |> Enum.find(fn artifact ->
      kind = artifact[:kind] || artifact["kind"]
      pr_merged = artifact[:pr_merged] || artifact["pr_merged"]
      kind == "pull_request" and pr_merged != true
    end)
  end

  def pending_review_artifact(_), do: nil

  def current_config_with_status_port(state) do
    if is_integer(state.status_port) and state.status_port > 0 do
      %{state.config | server_port: state.status_port}
    else
      state.config
    end
  end

  def build_recent_run(entry, result, completed_at_ms \\ System.system_time(:millisecond)) do
    %{
      issue_id: entry.issue.id,
      identifier: entry.issue_identifier,
      outcome: result_outcome(result),
      completed_at_ms: completed_at_ms,
      attempt: entry.retry_attempt,
      error: result_error(result),
      artifacts: result_artifacts(result),
      issue: summarize_issue(entry.issue),
      routing: summarize_routing(entry.routing),
      workspace_path: entry.workspace_path,
      session_id: entry.session_id
    }
  end

  def prepend_recent_run(recent_runs, recent_run) do
    [recent_run | recent_runs]
    |> Enum.take(20)
  end

  def update_recent_run_artifact(state, issue_id, updated_artifact) do
    recent_runs =
      Enum.map(state.recent_runs, fn run ->
        if run.issue_id == issue_id do
          artifacts =
            Enum.map(List.wrap(run.artifacts), fn artifact ->
              if same_review_artifact?(artifact, updated_artifact), do: updated_artifact, else: artifact
            end)

          %{run | artifacts: artifacts}
        else
          run
        end
      end)

    %{state | recent_runs: recent_runs}
  end

  def maybe_apply_runtime_update(entry, payload) do
    update_type = payload[:type] || payload[:event]

    entry =
      case update_type do
        :routing -> Map.put(entry, :routing, payload[:routing])
        _ -> entry
      end

    entry
    |> Map.put(:session_id, payload[:session_id] || entry.session_id)
    |> Map.put(:thread_id, payload[:thread_id] || entry.thread_id)
    |> Map.put(:turn_id, payload[:turn_id] || entry.turn_id)
    |> Map.put(:last_update_type, update_type)
  end

  def apply_phase_event(entry, type, details, now_ms \\ System.monotonic_time(:millisecond)) do
    case type do
      "workspace_setup_started" ->
        {Map.put(entry, :phase, "workspace_setup") |> Map.put(:phase_started_at_ms, now_ms), details}

      "workspace_setup_finished" ->
        details = maybe_put_phase_elapsed(details, entry, now_ms)
        {Map.put(entry, :phase, "planning") |> Map.put(:phase_started_at_ms, now_ms), details}

      "workspace_setup_failed" ->
        {entry, maybe_put_phase_elapsed(details, entry, now_ms)}

      "planning_turn_started" ->
        {Map.put(entry, :phase, "planning") |> Map.put(:phase_started_at_ms, now_ms), details}

      "planning_turn_finished" ->
        details = maybe_put_phase_elapsed(details, entry, now_ms)
        {Map.put(entry, :phase, "execution") |> Map.put(:phase_started_at_ms, now_ms), details}

      "planning_turn_failed" ->
        {entry, maybe_put_phase_elapsed(details, entry, now_ms)}

      "demo_capture_started" ->
        {Map.put(entry, :phase, "demo") |> Map.put(:phase_started_at_ms, now_ms), details}

      "demo_capture_succeeded" ->
        details = maybe_put_phase_elapsed(details, entry, now_ms)
        {Map.put(entry, :phase, "review_handoff") |> Map.put(:phase_started_at_ms, now_ms), details}

      "demo_capture_skipped" ->
        details = maybe_put_phase_elapsed(details, entry, now_ms)
        {Map.put(entry, :phase, "review_handoff") |> Map.put(:phase_started_at_ms, now_ms), details}

      "demo_capture_failed" ->
        {entry, maybe_put_phase_elapsed(details, entry, now_ms)}

      "workpad_synced" ->
        {entry, Map.put_new(details, "phase", entry.phase)}

      _ ->
        {entry, details}
    end
  end

  def summarize_running(running) do
    running
    |> Enum.map(fn {_issue_id, entry} -> summarize_running_entry(entry) end)
  end

  def summarize_retries(retry_attempts) do
    retry_attempts
    |> Enum.map(fn {_issue_id, retry} -> summarize_retry_entry(retry) end)
  end

  def summarize_running_entry(entry) do
    %{
      issue_id: entry.issue.id,
      identifier: entry.issue_identifier,
      title: entry.issue.title,
      url: entry.issue.url,
      state: entry.issue.state,
      started_at_ms: entry.started_at,
      retry_attempt: entry.retry_attempt,
      workspace_path: entry.workspace_path,
      routing: summarize_routing(entry.routing),
      session_id: entry.session_id,
      thread_id: entry.thread_id,
      turn_id: entry.turn_id,
      last_update_type: entry.last_update_type,
      codex_total_tokens: entry.codex_total_tokens,
      last_codex_timestamp: entry.last_codex_timestamp
    }
  end

  def summarize_retry_entry(retry) do
    %{
      issue_id: retry.issue_id,
      identifier: retry.identifier,
      attempt: retry.attempt,
      due_at_ms: retry.due_at_ms,
      error: retry.error
    }
  end

  def summarize_recent_runs(recent_runs) do
    Enum.map(recent_runs, &summarize_recent_run/1)
  end

  def summarize_recent_run(run) do
    %{
      issue_id: run.issue_id,
      identifier: run.identifier,
      outcome: run.outcome,
      completed_at_ms: run.completed_at_ms,
      attempt: run.attempt,
      error: run.error,
      artifacts: run.artifacts,
      demo: summarize_demo(run.artifacts),
      issue: run.issue,
      routing: run.routing,
      workspace_path: run.workspace_path,
      session_id: run.session_id
    }
  end

  def summarize_config(config) do
    %{
      tracker_kind: config.tracker_kind,
      tracker_project_slug: config.tracker_project_slug,
      poll_enabled: config.poll_enabled,
      poll_interval_ms: config.poll_interval_ms,
      max_concurrent_agents: config.max_concurrent_agents,
      workspace_root: config.workspace_root,
      server_port: config.server_port,
      codex_command: config.codex_command,
      codex_router_enabled: config.codex_router_enabled,
      codex_router_default_provider: config.codex_router_default_provider,
      codex_router_hard_provider: config.codex_router_hard_provider,
      codex_router_model: config.codex_router_model,
      codex_router_hard_model: config.codex_router_hard_model,
      codex_router_hard_percentile: config.codex_router_hard_percentile,
      codex_profiles: summarize_profiles(config.codex_profiles || %{}),
      recording_enabled: config.recording_enabled,
      recording_url: config.recording_url,
      recording_output_dir: config.recording_output_dir,
      recording_publish_to_tracker: config.recording_publish_to_tracker,
      recording_publish_comment: config.recording_publish_comment,
      review_pr_enabled: config.review_pr_enabled,
      review_required: config.review_required,
      review_pr_draft: config.review_pr_draft,
      review_pr_base_branch: config.review_pr_base_branch,
      review_pr_auto_merge: config.review_pr_auto_merge,
      github_webhook_auto_register: config.github_webhook_auto_register,
      github_webhook_provider: config.github_webhook_provider,
      github_webhook_repo: config.github_webhook_repo,
      linear_webhook_auto_register: config.linear_webhook_auto_register
    }
  end

  def summarize_profiles(profiles) do
    Enum.into(profiles, %{}, fn {name, profile} ->
      {name,
       %{
         name: profile[:name],
         base_url: profile[:base_url],
         model: profile[:model],
         model_provider: profile[:model_provider],
         auth_mode: profile[:auth_mode],
         backend: profile[:backend],
         command: profile[:command],
         has_api_key: not is_nil(profile[:api_key]) and profile[:api_key] != "",
         has_z_api_key: not is_nil(profile[:z_api_key]) and profile[:z_api_key] != "",
         env_keys: Map.keys(profile[:env] || %{})
       }}
    end)
  end

  def summarize_routing(nil), do: nil

  def summarize_routing(routing) when is_map(routing) do
    %{
      provider: routing[:provider] || routing["provider"],
      model: routing[:model] || routing["model"],
      model_provider: routing[:model_provider] || routing["model_provider"],
      effort: routing[:effort] || routing["effort"],
      hard_task?: routing[:hard_task?] || routing["hard_task?"],
      difficulty_score: routing[:difficulty_score] || routing["difficulty_score"],
      reason: routing[:reason] || routing["reason"]
    }
  end

  def summarize_issue(issue) when is_struct(issue, Issue) do
    %{
      id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      state: issue.state,
      url: issue.url,
      branch_name: issue.branch_name,
      comments: issue.comments || [],
      comments_text: issue.comments_text || ""
    }
  end

  def summarize_issue(_), do: nil

  def summarize_demo(artifacts) when is_list(artifacts) do
    case Enum.find(artifacts, fn artifact ->
           kind = artifact[:kind] || artifact["kind"]
           kind in ["video_recording", "demo_artifact"]
         end) do
      nil ->
        nil

      artifact ->
        verification = artifact[:verification] || artifact["verification"] || %{}
        results = verification[:results] || verification["results"] || []
        failed_results =
          Enum.filter(results, fn result -> (result[:passed] || result["passed"]) != true end)

        %{
          capture_type: artifact[:capture_type] || artifact["capture_type"] || "video",
          status: artifact[:status] || artifact["status"],
          demo_plan_path: artifact[:demo_plan_path] || artifact["demo_plan_path"],
          non_demoable: artifact[:non_demoable] || artifact["non_demoable"] || false,
          non_demoable_reason: artifact[:non_demoable_reason] || artifact["non_demoable_reason"],
          assertion_count: length(results),
          assertion_failures: Enum.count(results, &((&1[:passed] || &1["passed"]) != true)),
          failed_assertions: Enum.map(failed_results, &summarize_assertion_failure/1),
          verification_path: artifact[:verification_path] || artifact["verification_path"],
          video_path: artifact[:video_path] || artifact["video_path"],
          screenshot_path: artifact[:screenshot_path] || artifact["screenshot_path"],
          trace_path: artifact[:trace_path] || artifact["trace_path"],
          source_url: artifact[:source_url] || artifact["source_url"],
          linear_asset_url: artifact[:linear_asset_url] || artifact["linear_asset_url"],
          linear_attachment_id:
            artifact[:linear_attachment_id] || artifact["linear_attachment_id"],
          linear_comment_id: artifact[:linear_comment_id] || artifact["linear_comment_id"],
          published: artifact[:published] || artifact["published"] || false,
          error: artifact[:error] || artifact["error"]
        }
    end
  end

  def summarize_demo(_), do: nil

  def summarize_assertion_failure(result) do
    %{
      type: result[:type] || result["type"],
      selector: result[:selector] || result["selector"],
      value: result[:value] || result["value"],
      actual: result[:actual] || result["actual"],
      actual_url: result[:actual_url] || result["actual_url"],
      actual_present: result[:actual_present] || result["actual_present"]
    }
  end

  def summarize_events(events), do: Enum.map(events, &summarize_event/1)

  def summarize_issue_events(events, issue_identifier) do
    events
    |> Enum.filter(&(&1.issue_identifier == issue_identifier))
    |> summarize_events()
  end

  def summarize_event(event) do
    %{
      type: event.type,
      timestamp_ms: event.timestamp_ms,
      issue_identifier: event.issue_identifier,
      details: event.details
    }
  end

  defp maybe_put_phase_elapsed(details, entry, now_ms) do
    if is_integer(entry[:phase_started_at_ms]) do
      Map.put_new(details, "elapsed_ms", now_ms - entry.phase_started_at_ms)
    else
      details
    end
  end

  defp same_review_artifact?(left, right) do
    (left[:kind] || left["kind"]) == "pull_request" and
      (right[:kind] || right["kind"]) == "pull_request" and
      (left[:pr_number] || left["pr_number"]) == (right[:pr_number] || right["pr_number"]) and
      (left[:repo_slug] || left["repo_slug"]) == (right[:repo_slug] || right["repo_slug"])
  end

  defp result_outcome({:ok, _}), do: "completed"
  defp result_outcome({:error, _}), do: "failed"
  defp result_outcome(_), do: "unknown"

  defp result_error({:error, payload}), do: inspect(error_reason(payload))
  defp result_error(_), do: nil

  defp result_artifacts({_status, %{artifacts: artifacts}}) when is_list(artifacts), do: artifacts
  defp result_artifacts(_), do: []

  defp error_reason(%{reason: reason}), do: reason
  defp error_reason(reason), do: reason
end
