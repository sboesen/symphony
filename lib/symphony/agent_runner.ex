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
        |> maybe_capture_artifacts(issue, attempt, config, workspace_path, orchestrator_pid)
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

  defp maybe_capture_artifacts({:ok, _}, issue, attempt, config, workspace_path, orchestrator_pid) do
    capture_with_demo_repair(issue, attempt, config, workspace_path, orchestrator_pid, 2)
  end

  defp maybe_capture_artifacts(_, _issue, _attempt, _config, _workspace_path, _orchestrator_pid),
    do: {:ok, []}

  defp capture_with_demo_repair(issue, attempt, config, workspace_path, orchestrator_pid, attempts_left) do
    send_demo_event(orchestrator_pid, issue, "demo_capture_started", %{attempts_left: attempts_left})

    case ArtifactRecorder.capture(issue, attempt, workspace_path, config) do
      {:ok, artifacts} = ok ->
        Enum.each(artifacts, fn artifact ->
          send_demo_result_event(orchestrator_pid, issue, artifact)
        end)

        ok

      {:error, reason, _artifacts} = error when attempts_left > 1 ->
        send_demo_event(orchestrator_pid, issue, "demo_capture_repair_requested", %{
          attempts_left: attempts_left,
          reason: inspect(reason)
        })

        case repair_demo_plan(issue, attempt, config, workspace_path, orchestrator_pid, reason) do
          :ok ->
            capture_with_demo_repair(
              issue,
              attempt,
              config,
              workspace_path,
              orchestrator_pid,
              attempts_left - 1
            )

          {:error, _repair_reason} ->
            error
        end

      {:error, reason, artifacts} = error ->
        Enum.each(artifacts, fn artifact ->
          send_demo_result_event(orchestrator_pid, issue, artifact)
        end)

        send_demo_event(orchestrator_pid, issue, "demo_capture_failed", %{reason: inspect(reason)})
        error

      error ->
        error
    end
  end

  defp repair_demo_plan(issue, attempt, config, workspace_path, orchestrator_pid, reason) do
    prompt = demo_repair_prompt(issue, reason)
    routing = route_for_issue(issue, attempt, config)

    send(orchestrator_pid, {:codex_update, issue.id, %{type: :routing, routing: routing}})

    case Runner.run_turn(workspace_path, config, issue, attempt, prompt, routing, fn payload ->
           send(orchestrator_pid, {:codex_update, issue.id, payload})
         end) do
      {:ok, _summary} -> :ok
      {:error, repair_reason} -> {:error, repair_reason}
    end
  end

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
      prompt = maybe_append_demo_prompt(prompt, config)
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

  defp maybe_append_demo_prompt(prompt, config) when config.recording_enabled == true do
    recording_url = config.recording_url || "http://127.0.0.1:3000"

    prompt <>
      """

      Demo recording requirement:
      Before handing off, write a valid JSON demo plan to `.git/symphony/demo-plan.json` that shows the finished feature in action.
      The recorder will execute this plan automatically, so make it the shortest sequence that proves the user-visible change.
      If there is no meaningful user-visible demo for this task, you may instead mark the plan as non-demoable with a short reason.
      Use this base URL for the demo unless a different path in the same app is needed: #{recording_url}

      Demo plan schema:
      {
        "non_demoable": false,
        "reason": "Only required when non_demoable is true",
        "url": "#{recording_url}/path",
        "wait_for_text": "Optional text expected before demo begins",
        "wait_for_selector": "Optional selector expected before demo begins",
        "settle_ms": 1500,
        "assertions": [
          {"type": "text_present", "value": "Expected UI text"},
          {"type": "selector_visible", "selector": "[data-demo='ready']"},
          {"type": "selector_hidden", "selector": "[data-demo='loading']"},
          {"type": "url_includes", "value": "/feature"},
          {"type": "title_includes", "value": "Feature"},
          {"type": "selector_text_equals", "selector": "[data-demo='status']", "value": "Live"},
          {"type": "attribute_equals", "selector": "link[rel='alternate']", "attribute": "type", "value": "application/rss+xml"},
          {"type": "selector_count_at_least", "selector": "article", "value": 2},
          {"type": "text_absent", "value": "404"},
          {"type": "console_errors_absent"}
        ],
        "steps": [
          {"action": "wait", "ms": 1000},
          {"action": "click", "selector": "a[href='/feature']"},
          {"action": "scroll", "y": 900},
          {"action": "wait_for_text", "text": "Expected UI text"},
          {"action": "wait_for_selector", "selector": "[data-demo='ready']"},
          {"action": "press", "key": "Enter"},
          {"action": "type", "selector": "input[name='q']", "text": "query"},
          {"action": "goto", "url": "http://127.0.0.1:3000/other"},
          {"action": "scroll_to_selector", "selector": "#result"}
        ]
      }

      Rules:
      - Choose steps based on the actual feature you implemented, not a generic homepage capture.
      - Include only actions needed to demonstrate the change clearly.
      - Prefer stable selectors or obvious links/buttons.
      - Assertions are evaluated after all steps finish, so they must describe the final page state at the end of the demo.
      - Include assertions that prove the feature actually appeared and obvious regressions are absent.
      - If the task is backend-only or otherwise not meaningfully demoable, set `non_demoable` to true and explain why in `reason`.
      - The file must be valid JSON with double-quoted keys and strings.
      """
  end

  defp maybe_append_demo_prompt(prompt, _config), do: prompt

  defp demo_repair_prompt(issue, reason) do
    """
    The implementation is complete, but the feature demo plan failed verification.

    Issue: #{issue.identifier} - #{issue.title}
    Recording failure: #{inspect(reason)}

    Update only `.git/symphony/demo-plan.json` so the recorder can successfully demonstrate the feature.

    Requirements:
    - Keep the plan minimal and feature-specific.
    - Fix the assertions as well as the actions if needed.
    - If a meaningful demo is not possible, mark the plan as non-demoable with a short reason.
    - Do not make unrelated code changes.
    """
  end

  defp send_demo_result_event(orchestrator_pid, issue, artifact) do
    details =
      artifact
      |> Map.take([
        :status,
        :demo_plan_path,
        :non_demoable,
        :non_demoable_reason,
        :error,
        :verification
      ])
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

    case artifact[:status] do
      "ready" -> send_demo_event(orchestrator_pid, issue, "demo_capture_succeeded", details)
      "skipped" -> send_demo_event(orchestrator_pid, issue, "demo_capture_skipped", details)
      "error" -> send_demo_event(orchestrator_pid, issue, "demo_capture_failed", details)
      _ -> :ok
    end
  end

  defp send_demo_event(orchestrator_pid, issue, type, details) do
    send(orchestrator_pid, {:agent_runtime_event, issue.id, type, details})
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
