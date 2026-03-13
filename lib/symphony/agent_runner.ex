defmodule Symphony.AgentRunner do
  @moduledoc "Runs one per-issue attempt and reports updates back to orchestrator."

  @workpad_sync_debounce_ms 300
  @clarification_comment_id_path ".git/symphony/clarification-comment-id"

  alias Symphony.{
    AgentRunnerPrompt,
    ArtifactRecorder,
    CompletionResult,
    AgentRunnerDecision,
    AgentRunnerDemoPlan,
    CodexRouter,
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
    AgentRunnerPrompt.planning_prompt(issue)
  end

  defp maybe_append_comment_context(prompt, %Issue{comments_text: text})
       when is_binary(text) and text != "" do
    AgentRunnerPrompt.append_comment_context(prompt, %Issue{comments_text: text})
  end

  defp maybe_append_comment_context(prompt, _issue), do: prompt

  defp plan_repair_prompt(issue) do
    AgentRunnerPrompt.plan_repair_prompt(issue)
  end

  defp maybe_append_plan_context(prompt, workspace_path) do
    AgentRunnerPrompt.append_plan_context(prompt, workspace_path)
  end

  defp maybe_append_completion_prompt(prompt, config, workspace_path) do
    AgentRunnerPrompt.append_completion_prompt(prompt, config, workspace_path)
  end

  defp maybe_append_feedback_context(prompt, %Issue{feedback_assets_text: text})
       when is_binary(text) and text != "" do
    AgentRunnerPrompt.append_feedback_context(prompt, %Issue{feedback_assets_text: text})
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
    AgentRunnerDemoPlan.validate_file(path)
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
