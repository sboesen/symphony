defmodule Symphony.AgentRunner do
  @moduledoc "Runs one per-issue attempt and reports updates back to orchestrator."

  @workpad_sync_debounce_ms 300
  @clarification_comment_id_path ".git/symphony/clarification-comment-id"

  alias Symphony.{
    ArtifactRecorder,
    CompletionResult,
    AgentRunnerDecision,
    CodexRouter,
    DemoPlan,
    FeedbackAssets,
    GitReview,
    Issue,
    PlanContract,
    Runner,
    TemplateRenderer,
    Tracker,
    WorkspaceManager,
    WorkspaceSnapshot
  }

  def run(issue, attempt, config, prompt_template, orchestrator_pid) do
    hooks = hook_map(config)
    send(orchestrator_pid, {:agent_runtime_event, issue.id, "workspace_setup_started", %{attempt: attempt}})

    case WorkspaceManager.ensure_workspace(
           issue.identifier,
           config.workspace_root,
           hooks,
           config.hooks_timeout_ms
         ) do
      {:ok, _workspace, workspace_path} ->
        send(orchestrator_pid, {:agent_runtime_event, issue.id, "workspace_setup_finished", %{workspace_path: workspace_path}})

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
        send(orchestrator_pid, {:agent_runtime_event, issue.id, "workspace_setup_failed", %{reason: inspect(reason)}})
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
           WorkspaceManager.run_before_run_hook(hooks, workspace_path, config.hooks_timeout_ms),
         {:ok, issue} <- refresh_issue(config, issue, orchestrator_pid),
         issue = FeedbackAssets.sync(issue, config, workspace_path),
         {:ok, _plan_sync} <- plan_and_sync(issue, attempt, config, workspace_path, orchestrator_pid) do
      turn_result =
        run_turn_loop(issue, attempt, config, prompt_template, workspace_path, orchestrator_pid)

      turn_result =
        maybe_handle_blocked_turn_result(turn_result, issue, config, workspace_path)

      workpad_result = sync_workpad(issue, config, workspace_path)

      final_artifact_result =
        turn_result
        |> merge_workpad_result(workpad_result)
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

  defp maybe_handle_blocked_turn_result({:error, {:blocked, completion}}, issue, config, workspace_path) do
    _ = maybe_publish_clarification(issue, completion, config, workspace_path)
    _ = Tracker.mark_todo(config, issue.id)

    {:error, {:clarification_requested, completion}}
  end

  defp maybe_handle_blocked_turn_result(result, _issue, _config, _workspace_path), do: result

  defp maybe_publish_clarification(issue, completion, config, workspace_path) do
    case clarification_body(completion) do
      nil -> :ok

      body ->
        preferred_comment_id = read_clarification_comment_id(workspace_path)

        case Tracker.publish_clarification(config, issue, body, preferred_comment_id) do
          {:ok, %{comment_id: comment_id}} = ok ->
            persist_clarification_comment_id(workspace_path, comment_id)
            ok

          other ->
            other
        end
    end
  end

  defp clarification_body(%{notes: notes, summary: summary}) do
    cond do
      is_binary(notes) and String.trim(notes) != "" -> String.trim(notes)
      is_binary(summary) and String.trim(summary) != "" -> String.trim(summary)
      true -> nil
    end
  end

  defp merge_workpad_result({:ok, payload}, {:ok, workpad}) do
    {:ok, Map.put(payload, :workpad, workpad)}
  end

  defp merge_workpad_result(other, _), do: other

  defp maybe_capture_artifacts({:ok, _}, issue, attempt, config, workspace_path, orchestrator_pid) do
    with :ok <- ensure_plan_ready_for_handoff(workspace_path) do
      capture_with_demo_repair(issue, attempt, config, workspace_path, orchestrator_pid, 2)
    else
      {:error, reason} -> {:error, reason, []}
    end
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
      {:ok, _summary} ->
        case validate_demo_plan_contract(workspace_path) do
          :ok -> :ok
          {:error, repair_reason} -> {:error, repair_reason}
        end

      {:error, repair_reason} ->
        {:error, repair_reason}
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

  defp maybe_publish_artifacts({:error, reason, artifacts}, _issue, _config),
    do: {:error, reason, artifacts}

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

  defp maybe_publish_review_handoff({:error, reason, artifacts}, _turn_result, _issue, _workspace_path, _config, _branch_info),
    do: {:error, reason, artifacts}

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
      execution_turn? = true

      prompt =
        prompt
        |> maybe_append_comment_context(issue)
        |> maybe_append_feedback_context(issue)
        |> maybe_append_plan_context(workspace_path)
        |> maybe_append_completion_prompt(config, workspace_path)
      routing = route_for_issue(issue, attempt, config)
      workspace_snapshot = WorkspaceSnapshot.capture(workspace_path)
      reset_progress_sync_state()

      send(orchestrator_pid, {:codex_update, issue.id, %{type: :routing, routing: routing}})

      if execution_turn? do
        send(
          orchestrator_pid,
          {:agent_runtime_event, issue.id, "execution_turn_started", %{turn_index: turn_index}}
        )
      end

      turn_result =
        Runner.run_turn(workspace_path, config, issue, attempt, prompt, routing, fn payload ->
          send(orchestrator_pid, {:codex_update, issue.id, payload})
          maybe_sync_workpad_progress(issue, config, workspace_path, orchestrator_pid)
        end)

      turn_result = maybe_salvage_turn_result(turn_result, workspace_path, orchestrator_pid, issue)

      if execution_turn? do
        case turn_result do
          {:ok, _} ->
            send(
              orchestrator_pid,
              {:agent_runtime_event, issue.id, "execution_turn_finished", %{turn_index: turn_index}}
            )

          {:error, reason} ->
            send(
              orchestrator_pid,
              {:agent_runtime_event, issue.id, "execution_turn_failed", %{
                turn_index: turn_index,
                reason: inspect(reason)
              }}
            )
        end
      end

      with {:ok, completion_summary} <- turn_result,
           {:ok, completion} <- resolve_completion_result(completion_summary, workspace_path),
           {:ok, completion} <-
             maybe_repair_plan_for_completion(
               completion,
               issue,
               attempt,
               config,
               workspace_path,
               orchestrator_pid
             ),
           {:ok, refreshed_issue} <- refresh_issue(config, issue, orchestrator_pid) do
        case next_turn_action(
               completion,
               refreshed_issue,
               config,
               turn_index,
               max_turns,
               workspace_path,
               workspace_snapshot
             ) do
          :stop ->
            {:ok, %{status: completion.status, completion: completion}}

          :continue ->
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

          {:error, reason} ->
            {:error, reason}
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

  defp plan_and_sync(issue, attempt, config, workspace_path, orchestrator_pid) do
    prompt = planning_prompt(issue)
    routing = route_for_issue(issue, attempt, config)

    send(orchestrator_pid, {:codex_update, issue.id, %{type: :routing, routing: routing}})
    send_demo_event(orchestrator_pid, issue, "planning_turn_started", %{workspace_path: workspace_path})

    with {:ok, _summary} <-
           Runner.run_turn(workspace_path, config, issue, attempt, prompt, routing, fn payload ->
             send(orchestrator_pid, {:codex_update, issue.id, payload})
           end)
           |> maybe_salvage_plan_result(workspace_path, orchestrator_pid, issue),
         {:ok, _plan} <- load_plan_result(workspace_path),
         {:ok, workpad} <- sync_workpad(issue, config, workspace_path) do
      send_demo_event(orchestrator_pid, issue, "planning_turn_finished", %{})

      if is_map(workpad) do
        send_demo_event(orchestrator_pid, issue, "workpad_synced", %{
          comment_id: workpad[:comment_id],
          action: workpad[:action],
          elapsed_ms: workpad[:elapsed_ms]
        })
      end

      {:ok, workpad}
    else
      {:error, reason} ->
        send_demo_event(orchestrator_pid, issue, "planning_turn_failed", %{reason: inspect(reason)})
        {:error, reason}
    end
  end

  defp sync_workpad(issue, config, workspace_path) do
    sync_started_at = System.monotonic_time(:millisecond)

    with {:ok, plan} <- load_plan_result(workspace_path),
         true <- PlanContract.has_steps?(plan) or {:error, :plan_missing_steps},
         rendered = PlanContract.render_workpad(plan),
         {:ok, workpad} <-
           Tracker.upsert_workpad(config, issue, rendered, current_workpad_comment_id(workspace_path)) do
      remember_synced_workpad(rendered)
      remember_workpad_comment_id(workspace_path, workpad[:comment_id])
      {:ok, Map.put(workpad, :elapsed_ms, System.monotonic_time(:millisecond) - sync_started_at)}
    else
      {:error, :rate_limited} ->
        {:ok,
         %{
           comment_id: current_workpad_comment_id(workspace_path),
           action: :deferred_rate_limited,
           elapsed_ms: System.monotonic_time(:millisecond) - sync_started_at
         }}

      {:error, :missing} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
      false -> {:error, :plan_missing_steps}
    end
  end

  defp planning_prompt(issue) do
    """
    Create the execution plan for this issue before implementation.

    Issue: #{issue.identifier} - #{issue.title}
    Issue URL: #{issue.url}
    Issue description:
    #{issue.description}

    Recent comments:
    #{issue.comments_text}
    #{issue.feedback_assets_text}

    Write a valid JSON work plan to `.git/symphony/plan.json`.
    Do not make code changes in this planning pass unless the repo already has local work that must be inspected.

    Plan schema:
    {
      "summary": "Short summary of the intended approach",
      "targets": {
        "surface": "Optional short description of the thing being changed",
        "artifacts": ["Optional concrete anchors like routes, files, endpoints, docs pages"]
      },
      "steps": [
        {
          "id": "1",
          "content": "Top-level task",
          "status": "pending | in_progress | completed | blocked",
          "children": [
            {
              "id": "1.1",
              "content": "Sub-step",
              "status": "pending | in_progress | completed | blocked"
            }
          ]
        }
      ]
    }

    Rules:
    - If there are recent human comments, treat them as the latest authoritative correction to the task. They override your earlier attempt, earlier plan text, and any previous implementation that conflicts with them.
    - Ground the plan in the exact user-visible surface named in the issue. Do not substitute a nearby page or component.
    - `targets` is optional. Use it when it helps name the thing being changed, but do not force everything into a route/file shape.
    - If the task clearly names a page, route, endpoint, file, or document, mention that exact thing in either the summary, targets, or step text.
    - Do not include test-running, build-running, or dev-server-running steps when the execution contract forbids those commands. If validation commands are disallowed, plan for code changes and note the validation limitation truthfully.
    - Produce 2-6 top-level steps.
    - Use child steps only when they clarify implementation order.
    - Start everything as `pending`.
    - This plan will drive execution. Prefer editing the plan as reality changes instead of working off a private mental checklist.
    - If you discover a better approach, update the plan structure first and then follow it.
    - If the issue text is ambiguous about the target surface, do not guess. Keep the plan conservative and expect to ask for clarification later instead of silently changing a different page.
    - The plan should be concrete enough that a human can review progress from the checklist alone.
    - The file must be valid JSON with double-quoted keys and strings.
    """
  end

  defp maybe_append_comment_context(prompt, %Issue{comments_text: text})
       when is_binary(text) and text != "" do
    prompt <>
      """

      Recent human feedback:
      #{text}

      Feedback contract:
      - Treat the latest human comment as authoritative correction to the task.
      - If the latest human comment says the previous attempt was wrong, do not repeat the previous plan or implementation.
      - Prefer satisfying the newest human feedback over preserving an earlier approach.
      """
  end

  defp maybe_append_comment_context(prompt, _issue), do: prompt

  defp plan_repair_prompt(issue) do
    """
    The implementation is complete, but the Symphony work plan is out of date.

    Issue: #{issue.identifier} - #{issue.title}

    Update only `.git/symphony/plan.json` so it accurately reflects the work already completed in the workspace.

    Rules:
    - Do not make product code changes.
    - Mark completed steps as `completed`.
    - If any remaining work is actually unfinished, mark it `in_progress`, `pending`, or `blocked` truthfully.
    - Keep the existing step structure and text stable unless it is obviously wrong, but do correct the plan if reality diverged from it.
    - The file must remain valid JSON.
    """
  end

  defp maybe_append_plan_context(prompt, workspace_path) do
    case load_plan_result(workspace_path) do
      {:ok, plan} ->
        prompt <>
          """

          Current execution plan:
          #{PlanContract.render_workpad(plan)}

          Plan contract:
          - Execute against the plan. Do not treat it as a one-time sketch.
          - `.git/symphony/plan.json` is the machine-editable plan, and Symphony mirrors it into Linear. The Linear plan comment is the authoritative shared view for humans.
          - Update `.git/symphony/plan.json` before you start a step, when you change the plan, and when you finish a step.
          - Keep exactly one currently active step marked `in_progress` while you are working on it, unless you are blocked.
          - If you add, remove, split, merge, or reorder work, update the plan first so the checklist stays truthful.
          - Update the status of every plan step so it reflects reality before you finish this turn.
          - If the work is complete, every plan step should be `completed`.
          - If you are blocked, mark the relevant step `blocked`.
          - Do not delete completed steps; keep the checklist stable and update statuses instead.
          """

      _ ->
        prompt
    end
  end

  defp maybe_append_completion_prompt(prompt, config, workspace_path) do
    prompt <>
      """

      Completion contract:
      Before you finish a turn, write a valid JSON result file to `.git/symphony/result.json`.
      Symphony uses this file to decide whether the issue is complete, blocked, or needs another turn.

      Result file schema:
      {
        "status": "completed | needs_more_work | blocked",
        "summary": "Short summary of what happened this turn",
        "tests": ["Commands you ran to validate the work"],
        "artifacts": ["Optional human-readable artifact paths or links"],
        "notes": "Optional follow-up or blocker details"
      }

      Rules:
      - Use `completed` only when the task is actually ready for review handoff.
      - Use `needs_more_work` if you made progress but the issue still requires another implementation turn.
      - Use `blocked` if you cannot continue without clarification, credentials, external fixes, or other missing prerequisites.
      - The file must be valid JSON with double-quoted keys and strings.
      """
      |> maybe_append_demo_prompt(config, workspace_path)
  end

  defp maybe_append_demo_prompt(prompt, config, workspace_path) when config.recording_enabled == true do
    recording_url = config.recording_url || "http://127.0.0.1:3000"
    demo_repo_context = demo_repo_context_prompt(workspace_path)

    prompt <>
      """

      Demo recording requirement:
      If `.git/symphony/result.json` uses `"status": "completed"`, also write a valid JSON demo plan to `.git/symphony/demo-plan.json` that shows the finished feature in action.
      The recorder will execute this plan automatically, so make it the shortest sequence that proves the user-visible change.
      If there is no meaningful user-visible demo for this task, you may instead mark the plan as non-demoable with a short reason.
      Use this base URL for the demo unless a different path in the same app is needed: #{recording_url}

      Demo plan schema:
      {
        "capture": "video",
        "non_demoable": false,
        "reason": "Only required when non_demoable is true",
        "setup_command": "Optional command to start the local app needed for the demo",
        "teardown_command": "Optional command to stop or clean up the local app after capture",
        "ready_url": "Optional URL the recorder should wait for before opening the demo page",
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
      - Choose `"capture": "video"` for motion or interaction: clicks, typing, scrolling, navigation, transitions, menus, dropdowns, or multi-step flows.
      - Choose `"capture": "screenshot"` by default for static visual proof: removed/added sections, spacing, typography, color, layout, icon, badge, copy, or a single final rendered state.
      - Only choose `"capture": "video"` when motion or interaction is actually necessary to prove the change.
      - If the demo needs a local app server or other local process, provide a deterministic `setup_command` and, when helpful, a `ready_url`.
      - Inspect the actual workspace before choosing `setup_command`, `ready_url`, or `url`. Use the repo's real framework/dev command and real port, not a generic guess.
      - If `url` or `ready_url` points at `127.0.0.1`, `localhost`, or another local dev URL, include a `setup_command` unless the issue explicitly says the app is already running externally.
      - Do not assume port `3000`. Choose a concrete host and port that matches the actual app you inspected, and include that same host/port consistently in `setup_command`, `ready_url`, and `url`.
      - Do not use a vague command like bare `npm run dev` when a local URL is involved. Prefer an explicit command that binds the expected host/port, such as adding `-- --host 127.0.0.1 --port <port>` when the framework supports it.
      - `setup_command` must work in a fresh workspace clone, but do not add `npm install`, `pnpm install`, or similar bootstrap by default. Only include dependency installation if you verified the workspace actually needs it for this demo.
      - Use `teardown_command` only when the setup needs explicit cleanup beyond normal process termination.
      - Choose steps based on the actual feature you implemented, not a generic homepage capture.
      - Include only actions needed to demonstrate the change clearly.
      - Prefer stable selectors or obvious links/buttons.
      - Demo assertions are only artifact sanity checks. They are not unit tests or integration tests.
      - For `"capture": "screenshot"`, use no assertions unless the recorder explicitly needs one trivial selector check to avoid a blank page.
      - For `"capture": "video"`, use at most 1 to 3 assertions.
      - Any assertions must only cover the requested visible change and the final on-screen state needed to prove it.
      - Do not add broad page sanity checks, unrelated content checks, or generic regression checks.
      - Assertions are evaluated after all steps finish, so they must describe only the final demo state.
      - If the task is backend-only or otherwise not meaningfully demoable, set `non_demoable` to true and explain why in `reason`.
      - The file must be valid JSON with double-quoted keys and strings.

      #{demo_repo_context}
      """
  end

  defp maybe_append_demo_prompt(prompt, _config, _workspace_path), do: prompt

  defp maybe_append_feedback_context(prompt, %Issue{feedback_assets_text: text})
       when is_binary(text) and text != "" do
    prompt <>
      """

      Additional feedback context:
      #{text}
      """
  end

  defp maybe_append_feedback_context(prompt, _issue), do: prompt

  defp persist_clarification_comment_id(workspace_path, comment_id)
       when is_binary(workspace_path) and is_binary(comment_id) and comment_id != "" do
    path = Path.join(workspace_path, @clarification_comment_id_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, comment_id)
    :ok
  end

  defp read_clarification_comment_id(workspace_path) when is_binary(workspace_path) do
    path = Path.join(workspace_path, @clarification_comment_id_path)

    case File.read(path) do
      {:ok, comment_id} ->
        case String.trim(comment_id) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp demo_repo_context_prompt(workspace_path) do
    case detect_demo_repo_context(workspace_path) do
      nil ->
        "Repo demo context: none detected. Inspect the workspace before choosing any local demo setup."

      context ->
        lines =
          [
            "Repo demo context:",
            maybe_context_line("Detected framework", context[:framework]),
            maybe_context_line("Likely package manager", context[:package_manager]),
            maybe_context_line("Detected dev script", context[:dev_script]),
            maybe_context_line("Suggested local demo command", context[:suggested_setup_command]),
            maybe_context_line("Suggested local demo URL", context[:suggested_url]),
            maybe_context_line("Note", context[:note])
          ]
          |> Enum.reject(&is_nil/1)

        Enum.join(lines, "\n")
    end
  end

  defp maybe_context_line(_label, nil), do: nil
  defp maybe_context_line(label, value), do: "- #{label}: #{value}"

  defp detect_demo_repo_context(workspace_path) do
    package_json_path = Path.join(workspace_path, "package.json")

    with true <- File.exists?(package_json_path),
         {:ok, raw} <- File.read(package_json_path),
         {:ok, decoded} <- Jason.decode(raw),
         true <- is_map(decoded) do
      build_demo_repo_context(workspace_path, decoded)
    else
      _ -> nil
    end
  end

  defp build_demo_repo_context(workspace_path, package_json) do
    scripts = Map.get(package_json, "scripts", %{})
    deps = Map.get(package_json, "dependencies", %{})
    dev_deps = Map.get(package_json, "devDependencies", %{})
    dev_script = if is_map(scripts), do: Map.get(scripts, "dev"), else: nil
    package_manager = detect_package_manager(workspace_path, package_json)
    framework = detect_framework(package_json, deps, dev_deps, dev_script)

    suggested =
      case {framework, package_manager, dev_script} do
        {"astro", manager, script} when is_binary(manager) and is_binary(script) ->
          %{
            suggested_setup_command: "#{manager} run dev --host 127.0.0.1 --port 4321 --strictPort",
            suggested_url: "http://127.0.0.1:4321/",
            note: "Astro dev defaults to port 4321; prefer screenshot capture for static page changes."
          }

        {framework_name, manager, script} ->
          %{
            suggested_setup_command: generic_setup_command(manager, script),
            suggested_url: nil,
            note:
              generic_demo_note(framework_name, manager, script)
          }
      end

    %{
      framework: framework,
      package_manager: package_manager,
      dev_script: dev_script,
      suggested_setup_command: suggested[:suggested_setup_command],
      suggested_url: suggested[:suggested_url],
      note: suggested[:note]
    }
  end

  defp detect_package_manager(workspace_path, package_json) do
    case Map.get(package_json, "packageManager") do
      value when is_binary(value) and value != "" ->
        value |> String.split("@") |> List.first()

      _ ->
        cond do
          File.exists?(Path.join(workspace_path, "pnpm-lock.yaml")) -> "pnpm"
          File.exists?(Path.join(workspace_path, "yarn.lock")) -> "yarn"
          File.exists?(Path.join(workspace_path, "bun.lock")) -> "bun"
          File.exists?(Path.join(workspace_path, "bun.lockb")) -> "bun"
          File.exists?(Path.join(workspace_path, "package-lock.json")) -> "npm"
          true -> nil
        end
    end
  end

  defp detect_framework(package_json, deps, dev_deps, dev_script) do
    package_name = Map.get(package_json, "name", "")

    cond do
      Map.has_key?(deps, "astro") or Map.has_key?(dev_deps, "astro") or
          (is_binary(dev_script) and String.contains?(dev_script, "astro dev")) ->
        "astro"

      Map.has_key?(deps, "next") or Map.has_key?(dev_deps, "next") or
          (is_binary(dev_script) and String.contains?(dev_script, "next dev")) ->
        "next"

      Map.has_key?(deps, "vite") or Map.has_key?(dev_deps, "vite") or
          (is_binary(dev_script) and String.contains?(dev_script, "vite")) ->
        "vite"

      Map.has_key?(deps, "gatsby") or Map.has_key?(dev_deps, "gatsby") ->
        "gatsby"

      is_binary(package_name) and package_name != "" ->
        package_name

      true ->
        nil
    end
  end

  defp generic_setup_command(manager, script)
       when is_binary(manager) and manager in ["npm", "pnpm", "yarn", "bun"] and is_binary(script) do
    case {manager, script} do
      {"npm", _} -> "npm run dev"
      {"pnpm", _} -> "pnpm dev"
      {"yarn", _} -> "yarn dev"
      {"bun", _} -> "bun run dev"
    end
  end

  defp generic_setup_command(_, _), do: nil

  defp generic_demo_note(framework, manager, script) do
    cond do
      is_binary(framework) and is_binary(script) ->
        "Inspect the repo's dev server behavior and choose an explicit host/port before writing the demo plan."

      is_binary(manager) ->
        "A package manager was detected, but the demo plan still needs to inspect the repo before choosing a host/port."

      true ->
        "No clear app-server context detected; only use local demo setup if you verify it from the workspace."
    end
  end

  defp ensure_plan_ready_for_handoff(workspace_path) do
    case load_plan_result(workspace_path) do
      {:ok, plan} ->
        if PlanContract.all_done?(plan) do
          :ok
        else
          {:error, :plan_not_fully_completed}
        end

      {:error, :missing} ->
        {:error, :plan_missing}

      {:error, reason} ->
        {:error, {:plan_invalid, reason}}
    end
  end

  defp maybe_repair_plan_for_completion(
         %{status: "completed"} = completion,
         issue,
         attempt,
         config,
         workspace_path,
         orchestrator_pid
       ) do
    case ensure_plan_ready_for_handoff(workspace_path) do
      :ok ->
        {:ok, completion}

      {:error, reason} when reason in [:plan_not_fully_completed, :plan_missing] ->
        prompt = plan_repair_prompt(issue)
        routing = route_for_issue(issue, attempt, config)

        send(orchestrator_pid, {:codex_update, issue.id, %{type: :routing, routing: routing}})

        with {:ok, _summary} <-
               Runner.run_turn(workspace_path, config, issue, attempt, prompt, routing, fn payload ->
                 send(orchestrator_pid, {:codex_update, issue.id, payload})
               end)
               |> maybe_salvage_plan_result(workspace_path, orchestrator_pid, issue),
             {:ok, _plan} <- load_plan_result(workspace_path),
             {:ok, _workpad} <- sync_workpad(issue, config, workspace_path),
             :ok <- ensure_plan_ready_for_handoff(workspace_path) do
          {:ok, completion}
        else
          {:error, repair_reason} ->
            maybe_finalize_plan_deterministically(
              completion,
              issue,
              config,
              workspace_path,
              orchestrator_pid,
              repair_reason
            )
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_repair_plan_for_completion(completion, _issue, _attempt, _config, _workspace_path, _orchestrator_pid),
    do: {:ok, completion}

  defp maybe_finalize_plan_deterministically(
         completion,
         issue,
         config,
         workspace_path,
         orchestrator_pid,
         reason
       ) do
    with {:ok, plan} <- load_plan_result(workspace_path),
         updated_plan = PlanContract.mark_all_completed(plan),
         :ok <- write_plan_result(workspace_path, updated_plan),
         {:ok, workpad} <-
           Tracker.upsert_workpad(
             config,
             issue,
             PlanContract.render_workpad(updated_plan),
             current_workpad_comment_id(workspace_path)
           ),
         _ <- remember_workpad_comment_id(workspace_path, workpad[:comment_id]),
         :ok <- ensure_plan_ready_for_handoff(workspace_path) do
      send_demo_event(orchestrator_pid, issue, "workpad_completed_deterministically", %{
        reason: inspect(reason)
      })

      {:ok, completion}
    else
      {:error, deterministic_reason} -> {:error, deterministic_reason}
    end
  end

  defp demo_repair_prompt(issue, reason) do
    """
    The implementation is complete, but the feature demo plan failed verification.

    Issue: #{issue.identifier} - #{issue.title}
    Recording failure: #{inspect(reason)}

    Update only `.git/symphony/demo-plan.json` so the recorder can successfully demonstrate the feature.

    Requirements:
    - Keep the plan minimal and feature-specific.
    - Treat demo assertions only as artifact sanity checks, not as tests.
    - Use at most 1 to 3 assertions, and only for the specific visible change being demonstrated.
    - Remove unrelated content assertions or generic page checks.
    - Fix the assertions as well as the actions if needed.
    - If the demo uses a local URL such as `127.0.0.1` or `localhost`, inspect the workspace and use the repo's real dev command and real port. Do not guess `3000`.
    - Include a deterministic `setup_command` (and `ready_url` when helpful) so Symphony can start the app before capture.
    - Use the same explicit host/port consistently in `setup_command`, `ready_url`, and `url`.
    - Do not use a vague command like bare `npm run dev` for a local demo. Prefer an explicit host/port binding when the framework supports it.
    - Do not add dependency installation by default. Only include `npm install`, `pnpm install`, or similar if you verified the workspace actually needs it for this demo.
    - If a meaningful demo is not possible, mark the plan as non-demoable with a short reason.
    - Do not make unrelated code changes.
    """
  end

  defp validate_demo_plan_contract(workspace_path) do
    path = Path.join(workspace_path, ".git/symphony/demo-plan.json")

    with {:ok, decoded} <- DemoPlan.load_and_sanitize(path),
         :ok <- validate_demo_plan_map(decoded) do
      :ok
    else
      {:error, _reason} = error -> error
      _ -> {:error, :demo_plan_invalid}
    end
  end

  defp validate_demo_plan_map(%{"non_demoable" => true}), do: :ok

  defp validate_demo_plan_map(plan) when is_map(plan) do
    plan =
      case Map.get(plan, "capture") do
        "screenshot" -> Map.put(plan, "assertions", [])
        _ -> plan
      end

    ready_url = plan_string(plan, "ready_url")
    url = plan_string(plan, "url")
    setup_command = plan_string(plan, "setup_command")
    effective_url = ready_url || url || ""

    case URI.parse(effective_url) do
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

  defp validate_demo_plan_map(_), do: {:error, :demo_plan_invalid}

  defp plan_string(plan, key) when is_map(plan) do
    case Map.get(plan, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
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

  defp maybe_sync_workpad_progress(issue, config, workspace_path, orchestrator_pid) do
    now_ms = System.monotonic_time(:millisecond)
    last_sync_ms = Process.get(:symphony_workpad_last_sync_ms, 0)

    if now_ms - last_sync_ms >= @workpad_sync_debounce_ms do
      case load_plan_result(workspace_path) do
        {:ok, plan} ->
          if PlanContract.has_steps?(plan) do
            rendered = PlanContract.render_workpad(plan)
            last_body = Process.get(:symphony_workpad_last_body)

            if rendered != last_body do
              case Tracker.upsert_workpad(config, issue, rendered, current_workpad_comment_id(workspace_path)) do
                {:ok, workpad} ->
                  remember_synced_workpad(rendered)
                  remember_workpad_comment_id(workspace_path, workpad[:comment_id])

                  send_demo_event(orchestrator_pid, issue, "workpad_progress_synced", %{
                    comment_id: workpad[:comment_id],
                    action: workpad[:action]
                  })

                {:error, :rate_limited} ->
                  Process.put(:symphony_workpad_last_sync_ms, now_ms)

                _ ->
                  :ok
              end
            else
              Process.put(:symphony_workpad_last_sync_ms, now_ms)
            end
          end

        _ ->
          :ok
      end
    end
  end

  defp remember_synced_workpad(rendered) when is_binary(rendered) do
    Process.put(:symphony_workpad_last_body, rendered)
    Process.put(:symphony_workpad_last_sync_ms, System.monotonic_time(:millisecond))
    :ok
  end

  defp remember_workpad_comment_id(workspace_path, comment_id)
       when is_binary(workspace_path) and is_binary(comment_id) do
    Process.put(:symphony_workpad_comment_id, comment_id)
    File.mkdir_p!(Path.dirname(workpad_comment_id_path(workspace_path)))
    File.write!(workpad_comment_id_path(workspace_path), comment_id <> "\n")
    :ok
  end

  defp remember_workpad_comment_id(_, _), do: :ok

  defp current_workpad_comment_id(workspace_path) when is_binary(workspace_path) do
    case Process.get(:symphony_workpad_comment_id) do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        case File.read(workpad_comment_id_path(workspace_path)) do
          {:ok, value} ->
            trimmed = String.trim(value)

            if trimmed == "" do
              nil
            else
              Process.put(:symphony_workpad_comment_id, trimmed)
              trimmed
            end

          _ ->
            nil
        end
    end
  end

  defp current_workpad_comment_id(_), do: nil

  defp reset_progress_sync_state do
    Process.delete(:symphony_workpad_last_body)
    Process.delete(:symphony_workpad_last_sync_ms)
    Process.delete(:symphony_workpad_comment_id)
    :ok
  end

  defp workpad_comment_id_path(workspace_path) do
    Path.join(workspace_path, ".git/symphony/workpad-comment-id")
  end

  defp refresh_issue(config, issue, orchestrator_pid) do
    send_demo_event(orchestrator_pid, issue, "issue_refresh_started", %{})
    started_at = System.monotonic_time(:millisecond)

    case Tracker.fetch_states_by_ids(config, [issue.id]) do
      {:ok, [refreshed | _]} ->
        send_demo_event(orchestrator_pid, issue, "issue_refresh_finished", %{
          elapsed_ms: System.monotonic_time(:millisecond) - started_at
        })

        {:ok, refreshed}

      {:ok, []} ->
        send_demo_event(orchestrator_pid, issue, "issue_refresh_failed", %{
          reason: ":empty",
          elapsed_ms: System.monotonic_time(:millisecond) - started_at
        })

        {:ok, issue}

      {:error, reason} ->
        send_demo_event(orchestrator_pid, issue, "issue_refresh_failed", %{
          reason: inspect(reason),
          elapsed_ms: System.monotonic_time(:millisecond) - started_at
        })

        {:ok, issue}

      _ ->
        send_demo_event(orchestrator_pid, issue, "issue_refresh_failed", %{
          reason: ":unknown",
          elapsed_ms: System.monotonic_time(:millisecond) - started_at
        })

        {:ok, issue}
    end
  end

  defp next_turn_action(
         %{status: "completed"},
         _issue,
         _config,
         _turn_index,
         _max_turns,
         workspace_path,
         _workspace_snapshot
       ) do
    AgentRunnerDecision.next_turn_action(%{status: "completed"}, %{
      plan_ready: ensure_plan_ready_for_handoff(workspace_path)
    })
  end

  defp next_turn_action(
         %{status: "blocked"} = completion,
         _issue,
         _config,
         _turn_index,
         _max_turns,
         _workspace_path,
         _workspace_snapshot
       ),
       do: AgentRunnerDecision.next_turn_action(completion, %{})

  defp next_turn_action(
         %{status: "needs_more_work"} = completion,
         issue,
         config,
         turn_index,
         max_turns,
         workspace_path,
         workspace_snapshot
       ) do
    AgentRunnerDecision.next_turn_action(completion, %{
      turn_index: turn_index,
      max_turns: max_turns,
      issue_state: issue.state,
      active_states: config.tracker_active_states,
      progress_made?: WorkspaceSnapshot.progress_made?(workspace_path, workspace_snapshot)
    })
  end

  defp resolve_completion_result(%{completion: completion}, _workspace_path) when is_map(completion) do
    {:ok, completion}
  end

  defp resolve_completion_result(_summary, workspace_path) do
    load_completion_result(workspace_path)
  end

  defp load_completion_result(workspace_path) do
    case CompletionResult.load(workspace_path) do
      {:ok, result} ->
        {:ok, result}

      {:error, :missing} ->
        {:error, :completion_result_missing}

      {:error, reason} ->
        {:error, {:completion_result_invalid, reason}}
    end
  end

  defp load_plan_result(workspace_path) do
    case PlanContract.load(workspace_path) do
      {:ok, plan} ->
        {:ok, plan}

      {:error, :missing} ->
        {:error, :missing}

      {:error, reason} ->
        {:error, {:plan_invalid, reason}}
    end
  end

  defp write_plan_result(workspace_path, plan) when is_map(plan) do
    plan
    |> Jason.encode!(pretty: true)
    |> then(&File.write(PlanContract.path(workspace_path), &1 <> "\n"))
    |> case do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp hook_map(config) do
    %{
      after_create: config.hooks_after_create,
      before_run: config.hooks_before_run,
      after_run: config.hooks_after_run,
      before_remove: config.hooks_before_remove
    }
  end

  defp maybe_salvage_turn_result({:ok, _} = result, _workspace_path, _orchestrator_pid, _issue),
    do: result

  defp maybe_salvage_turn_result({:error, reason}, workspace_path, orchestrator_pid, issue) do
    case salvage_result(workspace_path, reason) do
      {:ok, payload} ->
        send_demo_event(orchestrator_pid, issue, "run_salvaged_from_workspace", %{
          reason: inspect(reason),
          status: payload[:status]
        })

        {:ok, payload}

      :no_salvage ->
        {:error, reason}
    end
  end

  defp maybe_salvage_turn_result(other, _workspace_path, _orchestrator_pid, _issue), do: other

  defp maybe_salvage_plan_result({:ok, _} = result, _workspace_path, _orchestrator_pid, _issue),
    do: result

  defp maybe_salvage_plan_result({:error, reason}, workspace_path, orchestrator_pid, issue) do
    if reason in [:stall_timeout, :turn_timeout] do
      case load_plan_result(workspace_path) do
        {:ok, _plan} ->
          send_demo_event(orchestrator_pid, issue, "plan_salvaged_from_workspace", %{
            reason: inspect(reason)
          })

          {:ok, %{status: "planned"}}

        _ ->
          {:error, reason}
      end
    else
      {:error, reason}
    end
  end

  defp salvage_result(workspace_path, reason) do
    AgentRunnerDecision.salvage_timeout_result(
      reason,
      CompletionResult.load(workspace_path),
      demo_plan_exists?(workspace_path),
      branch_has_committed_changes?(workspace_path)
    )
  end

  defp demo_plan_exists?(workspace_path) do
    File.exists?(Path.join(workspace_path, ".git/symphony/demo-plan.json"))
  end

  defp branch_has_committed_changes?(workspace_path) do
    case System.cmd("git", ["rev-list", "--count", "origin/main..HEAD"],
           cd: workspace_path,
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case Integer.parse(String.trim(out)) do
          {count, ""} when count > 0 -> true
          _ -> false
        end

      _ ->
        false
    end
  end
end
