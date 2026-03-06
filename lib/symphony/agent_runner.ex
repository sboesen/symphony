defmodule Symphony.AgentRunner do
  @moduledoc "Runs one per-issue attempt and reports updates back to orchestrator."

  alias Symphony.{
    ArtifactRecorder,
    CodexRouter,
    GitReview,
    Runner,
    TemplateRenderer,
    Tracker,
    WorkspaceManager
  }

  def run(issue, attempt, config, prompt_template, orchestrator_pid) do
    hooks = hook_map(config)

    case WorkspaceManager.ensure_workspace(
           issue.identifier,
           config.workspace_root,
           hooks,
           config.hooks_timeout_ms
         ) do
      {:ok, _workspace, workspace_path} ->
        result =
          run_attempt(
            issue,
            attempt,
            config,
            prompt_template,
            workspace_path,
            orchestrator_pid,
            hooks
          )

        send(orchestrator_pid, {:agent_run_result, issue.id, result})

      {:error, reason} ->
        send(orchestrator_pid, {:agent_run_result, issue.id, {:error, reason}})
    end
  end

  defp run_attempt(
         issue,
         attempt,
         config,
         prompt_template,
         workspace_path,
         orchestrator_pid,
       hooks
       ) do
    with {:ok, branch_info} <- GitReview.prepare_workspace(issue, workspace_path, config),
         :ok <-
           WorkspaceManager.run_before_run_hook(hooks, workspace_path, config.hooks_timeout_ms) do
      turn_result =
        run_turn_loop(issue, attempt, config, prompt_template, workspace_path, orchestrator_pid)

      final_artifact_result =
        turn_result
        |> maybe_capture_artifacts(issue, attempt, config, workspace_path)
        |> maybe_publish_artifacts(issue, config)
        |> maybe_publish_review_handoff(turn_result, issue, workspace_path, config, branch_info)

      _ = WorkspaceManager.run_after_run_hook(hooks, workspace_path, config.hooks_timeout_ms)
      normalize_result(turn_result, final_artifact_result)
    else
      {:error, reason} ->
        _ = WorkspaceManager.run_after_run_hook(hooks, workspace_path, config.hooks_timeout_ms)
        {:error, %{reason: reason, artifacts: []}}
    end
  end

  defp normalize_result({:ok, _}, {:ok, artifacts}) do
    {:ok, %{artifacts: artifacts}}
  end

  defp normalize_result({:ok, _}, {:error, reason, artifacts}) do
    {:error, %{reason: reason, artifacts: artifacts}}
  end

  defp normalize_result({:error, reason}, {:ok, artifacts}) do
    {:error, %{reason: reason, artifacts: artifacts}}
  end

  defp normalize_result({:error, reason}, {:error, _artifact_reason, artifacts}) do
    {:error, %{reason: reason, artifacts: artifacts}}
  end

  defp normalize_result(_, _), do: {:error, %{reason: :unknown_error, artifacts: []}}

  defp maybe_capture_artifacts({:ok, _}, issue, attempt, config, workspace_path) do
    ArtifactRecorder.capture(issue, attempt, workspace_path, config)
  end

  defp maybe_capture_artifacts(_, _issue, _attempt, _config, _workspace_path), do: {:ok, []}

  defp maybe_publish_artifacts({:ok, artifacts}, issue, config) when is_list(artifacts) do
    if config.recording_publish_to_tracker and artifacts != [] do
      case Tracker.publish_artifacts(config, issue, artifacts) do
        {:ok, published_artifacts} ->
          {:ok, published_artifacts}

        {:error, reason, published_artifacts} when config.recording_strict ->
          {:error, {:artifact_publish_failed, reason}, published_artifacts}

        {:error, _reason, published_artifacts} ->
          {:ok, published_artifacts}

        {:error, reason} when config.recording_strict ->
          {:error, {:artifact_publish_failed, reason}, artifacts}

        {:error, _reason} ->
          {:ok, artifacts}
      end
    else
      {:ok, artifacts}
    end
  end

  defp maybe_publish_artifacts({:error, _reason, artifacts}, _issue, _config), do: {:ok, artifacts}

  defp maybe_publish_review_handoff(
         {:ok, artifacts},
         {:ok, _},
         issue,
         workspace_path,
         config,
         branch_info
       ) do
    case GitReview.open_review_pr(issue, workspace_path, config, branch_info) do
      {:ok, nil} ->
        {:ok, artifacts}

      {:ok, review_artifact} ->
        case Tracker.publish_review_handoff(config, issue, review_artifact) do
          {:ok, published_review_artifact} ->
            {:ok, artifacts ++ [published_review_artifact]}

          {:error, reason} ->
            if config.review_pr_enabled do
              {:error, {:review_handoff_publish_failed, reason}, artifacts ++ [review_artifact]}
            else
              {:ok, artifacts ++ [review_artifact]}
            end
        end

      {:error, reason} ->
        {:error, {:review_pr_failed, reason}, artifacts}
    end
  end

  defp maybe_publish_review_handoff({:ok, artifacts}, _turn_result, _issue, _workspace_path, _config, _branch_info),
    do: {:ok, artifacts}

  defp maybe_publish_review_handoff({:error, _reason, artifacts}, _turn_result, _issue, _workspace_path, _config, _branch_info),
    do: {:ok, artifacts}

  defp run_turn_loop(issue, attempt, config, prompt_template, workspace_path, orchestrator_pid) do
    max_turns = max(1, config.max_turns)

    do_turn_loop(
      issue,
      attempt,
      config,
      prompt_template,
      workspace_path,
      orchestrator_pid,
      1,
      max_turns
    )
  end

  defp do_turn_loop(
         issue,
         attempt,
         config,
         prompt_template,
         workspace_path,
         orchestrator_pid,
         turn_index,
         max_turns
       ) do
    prompt_template = if turn_index == 1, do: prompt_template, else: continuation_prompt()

    with {:ok, prompt} <- TemplateRenderer.render(prompt_template, issue, attempt) do
      routing = route_for_issue(issue, attempt, config)

      send(orchestrator_pid, {:codex_update, issue.id, %{type: :routing, routing: routing}})

      turn_result =
        Runner.run_turn(workspace_path, config, issue, attempt, prompt, routing, fn payload ->
          send(orchestrator_pid, {:codex_update, issue.id, payload})
        end)

      with {:ok, _summary} <- turn_result,
           {:ok, refreshed_issue} <- refresh_issue(config, issue) do
        if turn_index < max_turns and active_state?(refreshed_issue, config.tracker_active_states) do
          do_turn_loop(
            refreshed_issue,
            attempt,
            config,
            prompt_template,
            workspace_path,
            orchestrator_pid,
            turn_index + 1,
            max_turns
          )
        else
          {:ok, :completed}
        end
      else
        {:error, reason} -> {:error, reason}
        :error -> {:error, :issue_refresh_failed}
      end
    end
  end

  defp route_for_issue(issue, attempt, config) do
    if config.codex_router_enabled do
      CodexRouter.route(issue, attempt, config,
        had_implementation_issues: is_integer(attempt) and attempt > 1
      )
    else
      provider = config.codex_router_default_provider || "zai"
      profile = Map.get(config.codex_profiles || %{}, provider, %{})

      %{
        provider: provider,
        model: profile[:model] || config.codex_model || "GLM-5",
        model_provider: profile[:model_provider] || config.codex_model_provider,
        auth_mode: profile[:auth_mode],
        effort: config.codex_reasoning_effort,
        hard_task?: false,
        difficulty_score: 0,
        reason: "router_disabled"
      }
    end
  end

  defp continuation_prompt do
    "Continue working on this issue using the current workspace state. Keep changes focused, validate key assumptions, and move the issue to the defined handoff condition when complete."
  end

  defp refresh_issue(config, issue) do
    case Tracker.fetch_states_by_ids(config, [issue.id]) do
      {:ok, [refreshed | _]} -> {:ok, refreshed}
      _ -> :error
    end
  end

  defp active_state?(issue, active_states) do
    normalized = Symphony.Issue.normalize_state(issue.state)
    normalized in active_states
  end

  defp hook_map(config) do
    %{
      after_create: config.hooks_after_create,
      before_run: config.hooks_before_run,
      after_run: config.hooks_after_run,
      before_remove: config.hooks_before_remove
    }
  end
end
