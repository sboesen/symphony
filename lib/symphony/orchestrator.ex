defmodule Symphony.Orchestrator do
  @moduledoc "Long-running scheduler loop and authoritative dispatch state."

  use GenServer
  require Logger

  alias Symphony.{Workflow, Config, Tracker, WorkspaceManager, Issue, GitReview, PlanContract}

  @heartbeat_interval_ms 5_000
  @handoff_pending_ttl_ms 30_000

  defstruct [
    :workflow_path,
    :workflow_mtime_ms,
    :config,
    :status_port,
    :prompt_template,
    :poll_enabled,
    :poll_interval_ms,
    paused: false,
    paused_reason: nil,
    paused_until_ms: nil,
    running: %{},
    claimed: MapSet.new(),
    handoff_pending: %{},
    retry_attempts: %{},
    completed: MapSet.new(),
    recent_runs: [],
    last_candidates: [],
    events: [],
    codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0.0},
    codex_rate_limits: nil
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  def issue_status(issue_identifier) when is_binary(issue_identifier) do
    GenServer.call(__MODULE__, {:issue_status, issue_identifier})
  end

  def current_config do
    GenServer.call(__MODULE__, :current_config)
  end

  def merge_review_handoff(issue_identifier, opts \\ [])

  def merge_review_handoff(issue_identifier, opts) when is_binary(issue_identifier) and is_list(opts) do
    GenServer.call(__MODULE__, {:merge_review_handoff, issue_identifier, opts}, 30_000)
  end

  def external_event(type, issue_identifier, details \\ %{}) do
    GenServer.call(__MODULE__, {:external_event, type, issue_identifier, details})
  end

  def refresh do
    GenServer.call(__MODULE__, :refresh)
  end

  def pause do
    GenServer.call(__MODULE__, :pause)
  end

  def resume do
    GenServer.call(__MODULE__, :resume)
  end

  def retry_issue(issue_identifier) when is_binary(issue_identifier) do
    GenServer.call(__MODULE__, {:retry_issue, issue_identifier})
  end

  def cancel_issue(issue_identifier) when is_binary(issue_identifier) do
    GenServer.call(__MODULE__, {:cancel_issue, issue_identifier})
  end

  def init(opts) do
    workflow_path = Keyword.get(opts, :workflow_path, "./WORKFLOW.md")

    with {:ok, workflow} <- Workflow.load(workflow_path),
         {:ok, config} <- Config.from_workflow(workflow),
         :ok <- Config.validate_dispatch(config),
         {:ok, status_port} <- Symphony.StatusServer.ensure_started(config.server_port) do
      state = %__MODULE__{
        workflow_path: workflow_path,
        workflow_mtime_ms: workflow.mtime_ms,
        config: config,
        status_port: status_port,
        prompt_template: workflow.prompt_template,
        poll_enabled: config.poll_enabled,
        poll_interval_ms: config.poll_interval_ms
      }

      state =
        log_event(state, "system_ready", nil, %{
          configured_server_port: config.server_port,
          status_port: status_port
        })
      cleanup_startup_terminals(state)
      state =
        state
        |> reconcile_running()
        |> reconcile_review_handoffs()
        |> maybe_resume_from_rate_limit_pause()
        |> dispatch_cycle()
      schedule_heartbeat(0)
      schedule_reconcile(0, config.poll_enabled)
      {:ok, state}
    else
      {:error, reason} ->
        {:stop, reason}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply, status_payload(state), state}
  end

  def handle_call({:issue_status, issue_identifier}, _from, state) do
    {:reply, issue_status_payload(state, issue_identifier), state}
  end

  def handle_call(:current_config, _from, state) do
    {:reply, current_config_with_status_port(state), state}
  end

  def handle_call({:merge_review_handoff, issue_identifier, opts}, _from, state) do
    {reply, state} = merge_review_handoff_now(state, issue_identifier, opts)
    {:reply, reply, state}
  end

  def handle_call({:external_event, type, issue_identifier, details}, _from, state) do
    state = log_event(state, type, issue_identifier, details)
    {:reply, :ok, state}
  end

  def handle_call(:refresh, _from, state) do
    state =
      state
      |> log_event("manual_refresh_requested", nil, %{})
      |> reconcile_running()
      |> reconcile_review_handoffs()
      |> maybe_resume_from_rate_limit_pause()
      |> dispatch_cycle()

    {:reply, {:ok, status_payload(state)}, state}
  end

  def handle_call(:pause, _from, state) do
    state = %{state | paused: true, paused_reason: "manual", paused_until_ms: nil}
    state = log_event(state, "scheduler_paused", nil, %{reason: "manual"})
    {:reply, {:ok, %{paused: true}}, state}
  end

  def handle_call(:resume, _from, state) do
    state = %{state | paused: false, paused_reason: nil, paused_until_ms: nil}
    state = log_event(state, "scheduler_resumed", nil, %{})
    {:reply, {:ok, %{paused: false}}, state}
  end

  def handle_call({:retry_issue, issue_identifier}, _from, state) do
    case issue_lookup(state, issue_identifier) do
      nil ->
        {:reply, {:error, :issue_not_found}, state}

      %{issue_id: issue_id, identifier: identifier} ->
        existing = Map.get(state.retry_attempts, issue_id)
        if existing && Map.has_key?(existing, :timer), do: Process.cancel_timer(existing.timer)

        state =
          state
          |> log_event("manual_retry_requested", identifier, %{issue_id: issue_id})
          |> schedule_retry(issue_id, identifier, 1, "manual_retry")

        {:reply, {:ok, %{issue_identifier: identifier, scheduled: true}}, state}
    end
  end

  def handle_call({:cancel_issue, issue_identifier}, _from, state) do
    issue_identifier = String.trim(issue_identifier)

    case running_issue_id(state, issue_identifier) do
      nil ->
        {:reply, {:error, :issue_not_running}, state}

      issue_id ->
        state =
          state
          |> log_event("manual_cancel_requested", issue_identifier, %{issue_id: issue_id})
          |> cancel_running_issue(issue_id)

        {:reply, {:ok, %{issue_identifier: issue_identifier, cancelled: true}}, state}
    end
  end

  def handle_info(:heartbeat, state) do
    state = maybe_reload_workflow(state)
    state = reconcile_stalled_runs(state)
    state = maybe_resume_from_rate_limit_pause(state)

    schedule_heartbeat(@heartbeat_interval_ms)
    {:noreply, state}
  end

  def handle_info(:reconcile, state) do
    state = maybe_reload_workflow(state)
    state = reconcile_running(state)
    state = reconcile_review_handoffs(state)
    state = maybe_resume_from_rate_limit_pause(state)

    state =
      case Config.validate_dispatch(state.config) do
        :ok ->
          if state.paused do
            state
          else
            dispatch_cycle(state)
          end

        {:error, reason} ->
          Logger.warning("dispatch blocked: #{inspect(reason)}")
          IO.puts("dispatch blocked: #{inspect(reason)}")
          log_event(state, "dispatch_blocked", nil, %{reason: inspect(reason)})
      end

    schedule_reconcile(state.poll_interval_ms, state.poll_enabled)
    {:noreply, state}
  end

  def handle_info({:agent_run_result, issue_id, result}, state) do
    case Map.get(state.running, issue_id) do
      nil ->
        {:noreply, state}

      entry ->
        recent_run = build_recent_run(entry, result)
        state = remove_running(state, issue_id)

        state =
          %{
            state
            | completed: MapSet.put(state.completed, issue_id),
	              handoff_pending:
	                if(state.config.review_required,
	                  do: Map.put(state.handoff_pending, issue_id, System.monotonic_time(:millisecond)),
	                  else: state.handoff_pending
	                ),
              recent_runs: prepend_recent_run(state.recent_runs, recent_run)
          }
          |> log_event("run_finished", entry.issue_identifier, %{
            outcome: recent_run.outcome,
            attempt: recent_run.attempt,
            error: recent_run.error
          })

        state =
          case result do
            {:ok, _payload} ->
              if state.config.review_required do
                case Tracker.mark_in_review(state.config, issue_id) do
                  :ok ->
                    log_event(state, "tracker_marked_in_review", entry.issue_identifier, %{
                      issue_id: issue_id
                    })

                  {:error, {:rate_limited, reset_ms}} ->
                    state
                    |> pause_for_rate_limit(reset_ms, "mark_in_review")
                    |> schedule_retry(issue_id, entry.issue_identifier, 1, "tracker_rate_limited")

                  {:error, reason} ->
                    Logger.warning(
                      "failed to mark issue #{entry.issue_identifier} in review: #{inspect(reason)}"
                    )

                    state
                    |> log_event("tracker_mark_in_review_failed", entry.issue_identifier, %{
                      issue_id: issue_id,
                      reason: inspect(reason)
                    })
                    |> schedule_retry(issue_id, entry.issue_identifier, 1, "normal_completion")
                end
              else
                case Tracker.mark_done(state.config, issue_id) do
                  :ok ->
                    log_event(state, "tracker_marked_done", entry.issue_identifier, %{
                      issue_id: issue_id
                    })

                  {:error, {:rate_limited, reset_ms}} ->
                    state
                    |> pause_for_rate_limit(reset_ms, "mark_done")
                    |> schedule_retry(issue_id, entry.issue_identifier, 1, "tracker_rate_limited")

                  {:error, reason} ->
                    Logger.warning(
                      "failed to mark issue #{entry.issue_identifier} done: #{inspect(reason)}"
                    )

                    state
                    |> log_event("tracker_mark_done_failed", entry.issue_identifier, %{
                      issue_id: issue_id,
                      reason: inspect(reason)
                    })
                    |> schedule_retry(issue_id, entry.issue_identifier, 1, "normal_completion")
                end
              end

            {:error, payload} ->
              reason = error_reason(payload)
              attempt = max(1, entry.retry_attempt || 0)

              Logger.warning(
                "agent run failed for issue #{entry.issue_identifier} (attempt=#{attempt}): #{inspect(reason)}"
              )

              next_state =
                state
                |> log_event("run_failed", entry.issue_identifier, %{
                  issue_id: issue_id,
                  attempt: attempt,
                  reason: inspect(reason)
                })

              cond do
                clarification_requested?(reason) ->
                  next_state
                  |> log_event("clarification_requested", entry.issue_identifier, %{
                    issue_id: issue_id,
                    attempt: attempt,
                    reason: inspect(reason)
                  })

                non_retryable_failure?(reason) ->
                  next_state
                  |> log_event("run_failed_non_retryable", entry.issue_identifier, %{
                    issue_id: issue_id,
                    attempt: attempt,
                    reason: inspect(reason)
                  })

                reset_ms = rate_limit_reset_ms(reason) ->
                  next_state
                  |> pause_for_rate_limit(reset_ms, "agent_run_failed")
                  |> schedule_retry(issue_id, entry.issue_identifier, attempt + 1, "tracker_rate_limited")

                true ->
                  next_state
                  |> schedule_retry(issue_id, entry.issue_identifier, attempt + 1, inspect(reason))
              end
          end

        {:noreply, state}
    end
  end

  def handle_info({:codex_update, issue_id, payload}, state) do
    case Map.get(state.running, issue_id) do
      nil ->
        {:noreply, state}

      entry ->
        usage =
          case payload[:usage] do
            nil -> %{}
            u -> u
          end

        updated_usage = %{
          usage_input: usage[:input_tokens] || 0,
          usage_output: usage[:output_tokens] || 0,
          usage_total: usage[:total_tokens] || 0
        }

        input_delta = max(0, updated_usage[:usage_input] - (entry.codex_input_tokens || 0))
        output_delta = max(0, updated_usage[:usage_output] - (entry.codex_output_tokens || 0))
        total_delta = max(0, updated_usage[:usage_total] - (entry.codex_total_tokens || 0))

        updated_entry =
          entry
          |> Map.put(:last_codex_timestamp, System.monotonic_time(:millisecond))
          |> Map.put(:codex_input_tokens, updated_usage[:usage_input])
          |> Map.put(:codex_output_tokens, updated_usage[:usage_output])
          |> Map.put(:codex_total_tokens, updated_usage[:usage_total])
          |> maybe_apply_runtime_update(payload)

        state =
          %{state | running: Map.put(state.running, issue_id, updated_entry)}

        state =
          %{
            state
            | codex_totals: %{
                input_tokens: state.codex_totals.input_tokens + input_delta,
                output_tokens: state.codex_totals.output_tokens + output_delta,
                total_tokens: state.codex_totals.total_tokens + total_delta,
                seconds_running: state.codex_totals.seconds_running
              }
          }

        state =
          case payload[:type] || payload[:event] do
            :routing ->
              log_event(state, "routing_selected", entry.issue_identifier, %{
                provider: payload[:routing][:provider],
                model: payload[:routing][:model],
                reason: payload[:routing][:reason]
              })

            :session_started ->
              log_event(state, "session_started", entry.issue_identifier, %{
                session_id: payload[:session_id],
                thread_id: payload[:thread_id],
                turn_id: payload[:turn_id]
              })

            _ ->
              state
          end

        {:noreply, state}
    end
  end

  def handle_info({:agent_runtime_event, issue_id, type, details}, state) do
    case Map.get(state.running, issue_id) do
      nil ->
        {:noreply, state}

      entry ->
        {updated_entry, details} =
          entry
          |> Map.put(:last_codex_timestamp, System.monotonic_time(:millisecond))
          |> Map.put(:last_update_type, to_string(type))
          |> apply_phase_event(to_string(type), details)

        state =
          state
          |> Map.put(:running, Map.put(state.running, issue_id, updated_entry))
          |> log_event(type, entry.issue_identifier, details)

        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    issue_id =
      state.running
      |> Enum.find_value(fn
        {id, entry} -> if entry.monitor_ref == ref or entry.pid == pid, do: id, else: nil
      end)

    if issue_id do
      entry = Map.get(state.running, issue_id)
      state = remove_running(state, issue_id)

      case reason do
        :normal ->
          {:noreply, state}

        _ ->
          state =
            state
            |> log_event("worker_crashed", entry.issue_identifier, %{
              issue_id: issue_id,
              reason: inspect(reason)
            })
            |> schedule_retry(
              issue_id,
              entry.issue_identifier,
              max(1, (entry.retry_attempt || 0) + 1),
              "worker_crash: #{inspect(reason)}"
            )

          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:retry_due, issue_id}, state) do
    case Map.get(state.retry_attempts, issue_id) do
      nil ->
        {:noreply, state}

      retry_entry ->
        state = %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}
        {:noreply, handle_retry_due(state, retry_entry)}
    end
  end

  defp handle_retry_due(state, retry_entry) do
    case Tracker.fetch_candidates(state.config) do
      {:ok, candidates} ->
        case Enum.find(candidates, &(&1.id == retry_entry.issue_id)) do
          nil ->
            %{state | claimed: MapSet.delete(state.claimed, retry_entry.issue_id)}

          issue ->
            if can_dispatch_now?(state, issue) do
              dispatch_issue(state, issue, retry_entry.attempt)
            else
              schedule_retry(
                %{state | claimed: MapSet.put(state.claimed, retry_entry.issue_id)},
                retry_entry.issue_id,
                issue.identifier,
                retry_entry.attempt + 1,
                retry_entry.error
              )
            end
        end

      {:error, reason} ->
        case rate_limit_reset_ms(reason) do
          nil ->
            schedule_retry(
              state,
              retry_entry.issue_id,
              retry_entry.identifier,
              retry_entry.attempt + 1,
              inspect(reason)
            )

          reset_ms ->
            state
            |> pause_for_rate_limit(reset_ms, "retry_fetch_candidates")
            |> schedule_retry(
              retry_entry.issue_id,
              retry_entry.identifier,
              retry_entry.attempt + 1,
              "tracker_rate_limited"
            )
        end
    end
  end

  defp cleanup_startup_terminals(state) do
    issues = Tracker.fetch_terminal_issues(state.config, state.config.tracker_terminal_states)

    case issues do
      {:ok, list} when is_list(list) ->
        Enum.each(list, fn issue ->
          path = workspace_path(issue.identifier, state.config.workspace_root)

          WorkspaceManager.cleanup_workspace(
            path,
            state.config.workspace_root,
            hook_map(state.config),
            state.config.hooks_timeout_ms
          )
        end)

      _ ->
        :ok
    end
  end

  defp maybe_reload_workflow(state) do
    with {:ok, workflow} <- Workflow.load(state.workflow_path) do
      if workflow.mtime_ms != state.workflow_mtime_ms do
        with {:ok, config} <- Config.from_workflow(workflow),
             :ok <- Config.validate_dispatch(config),
             {:ok, status_port} <- Symphony.StatusServer.ensure_started(config.server_port) do

          %{
            state
            | workflow_mtime_ms: workflow.mtime_ms,
              config: config,
              status_port: status_port,
              prompt_template: workflow.prompt_template,
              poll_enabled: config.poll_enabled,
              poll_interval_ms: config.poll_interval_ms
          }
          |> log_event("workflow_reloaded", nil, %{
            workflow_path: state.workflow_path,
            configured_server_port: config.server_port,
            status_port: status_port
          })
        else
          _ -> state
        end
      else
        state
      end
    else
      _ ->
        state
    end
  end

  defp dispatch_cycle(state) do
    case Tracker.fetch_candidates(state.config) do
      {:ok, issues} when is_list(issues) ->
        state = %{state | last_candidates: Enum.map(issues, &summarize_issue/1)}

        if issues == [] do
          Logger.info(
            "tracker returned 0 candidate issues (kind=#{state.config.tracker_kind}, project_slug=#{state.config.tracker_project_slug})"
          )

          state
          |> log_event("candidate_poll_completed", nil, %{count: 0})
        else
          sorted = sort_issues(issues)

          state =
            log_event(state, "candidate_poll_completed", nil, %{count: length(sorted)})

          sorted
          |> Enum.reduce(state, fn issue, acc ->
            cond do
              MapSet.member?(acc.claimed, issue.id) ->
                acc

              handoff_pending?(acc, issue.id) ->
                acc

              not can_dispatch_now?(acc, issue) ->
                acc

              true ->
                dispatch_issue(acc, issue, nil)
            end
          end)
        end

      {:ok, other} ->
        Logger.warning("tracker returned malformed candidates payload: #{inspect(other)}")
        log_event(state, "candidate_poll_malformed", nil, %{payload: inspect(other)})

      {:error, reason} ->
        Logger.warning("tracker fetch_candidates failed: #{inspect(reason)}")

        state =
          log_event(state, "candidate_poll_failed", nil, %{reason: inspect(reason)})

        case rate_limit_reset_ms(reason) do
          nil -> state
          reset_ms -> pause_for_rate_limit(state, reset_ms, "fetch_candidates")
        end
    end
  end

  defp sort_issues(issues) do
    Enum.sort_by(issues, fn issue ->
      {
        normalize_priority(issue.priority),
        issue.created_at || DateTime.from_unix!(0)
      }
    end)
  end

  defp normalize_priority(nil), do: 9999
  defp normalize_priority(v) when is_integer(v), do: v
  defp normalize_priority(v) when is_binary(v), do: parse_int(v)
  defp normalize_priority(_), do: 9999

  defp parse_int(v) do
    case Integer.parse(v) do
      {n, _} -> n
      _ -> 9999
    end
  end

  defp can_dispatch_now?(state, issue) do
    cond do
      reached_global_limit?(state) ->
        false

      reached_state_limit?(state, issue) ->
        false

      Issue.normalize_state(issue.state) in state.config.tracker_active_states ->
        if Issue.normalize_state(issue.state) == "todo" do
          not Issue.blocked_by_has_non_terminal?(issue, state.config.tracker_terminal_states)
        else
          true
        end

      true ->
        false
    end
  end

  defp reached_global_limit?(state),
    do: map_size(state.running) >= max(1, state.config.max_concurrent_agents)

  defp reached_state_limit?(state, issue) do
    issue_state = Issue.normalize_state(issue.state)
    limit = Map.get(state.config.max_concurrent_agents_by_state, issue_state)

    if is_nil(limit) do
      false
    else
      running_count_for_state(state, issue_state) >= limit
    end
  end

  defp dispatch_issue(state, issue, attempt) do
    orchestrator_pid = self()
    dispatch_attempt = if is_integer(attempt) and attempt > 0, do: attempt, else: 1
    path = workspace_path(issue.identifier, state.config.workspace_root)

    task_fn = fn ->
      Symphony.AgentRunner.run(
        issue,
        dispatch_attempt,
        state.config,
        state.prompt_template,
        orchestrator_pid
      )
    end

    state =
      log_event(state, "issue_dispatched", issue.identifier, %{
        issue_id: issue.id,
        attempt: dispatch_attempt
      })

    state =
      log_event(state, "tracker_mark_started_started", issue.identifier, %{
        issue_id: issue.id
      })

    mark_started_started_at = System.monotonic_time(:millisecond)

    state =
      case Tracker.mark_started(state.config, issue.id) do
        :ok ->
          log_event(state, "tracker_marked_started", issue.identifier, %{
            issue_id: issue.id,
            elapsed_ms: System.monotonic_time(:millisecond) - mark_started_started_at
          })

        {:error, {:rate_limited, reset_ms}} ->
          state
          |> log_event("tracker_mark_started_failed", issue.identifier, %{
            issue_id: issue.id,
            reason: ":rate_limited",
            elapsed_ms: System.monotonic_time(:millisecond) - mark_started_started_at
          })
          |> pause_for_rate_limit(reset_ms, "mark_started")

        {:error, reason} ->
          Logger.warning("failed to mark issue #{issue.identifier} started: #{inspect(reason)}")

          log_event(state, "tracker_mark_started_failed", issue.identifier, %{
            issue_id: issue.id,
            reason: inspect(reason),
            elapsed_ms: System.monotonic_time(:millisecond) - mark_started_started_at
          })
      end

    state = maybe_sync_placeholder_workpad(state, issue, path)

    case Task.Supervisor.start_child(Symphony.TaskSupervisor, task_fn) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)

        running_entry = %{
          pid: pid,
          monitor_ref: monitor,
          issue: issue,
          issue_identifier: issue.identifier,
          started_at: System.monotonic_time(:millisecond),
          attempt: dispatch_attempt,
          workspace_path: path,
          routing: nil,
          retry_attempt: dispatch_attempt,
          last_codex_timestamp: nil,
          session_id: nil,
          thread_id: nil,
          turn_id: nil,
          last_update_type: nil,
          phase: "dispatched",
          phase_started_at_ms: System.monotonic_time(:millisecond),
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0
        }

        %{
          state
          | running: Map.put(state.running, issue.id, running_entry),
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        state
        |> log_event("issue_dispatch_failed", issue.identifier, %{
          issue_id: issue.id,
          reason: inspect(reason)
        })
        |> schedule_retry(issue.id, issue.identifier, 1, inspect(reason))
    end
  end

  defp remove_running(state, issue_id) do
    running_entry = Map.get(state.running, issue_id)

    if running_entry do
      try do
        Task.Supervisor.terminate_child(Symphony.TaskSupervisor, running_entry.pid)
      rescue
        _ -> :ok
      end
    end

    %{
      state
      | running: Map.delete(state.running, issue_id),
        claimed: MapSet.delete(state.claimed, issue_id)
    }
  end

  defp schedule_retry(state, issue_id, identifier, attempt, error) do
    delay =
      if error == "normal_completion" do
        1_000
      else
        retry_delay_ms(attempt, state.config.max_retry_backoff_ms)
      end

    timer = Process.send_after(self(), {:retry_due, issue_id}, delay)

    existing = Map.get(state.retry_attempts, issue_id)
    if existing && Map.has_key?(existing, :timer), do: Process.cancel_timer(existing.timer)

    entry = %{
      issue_id: issue_id,
      identifier: identifier,
      attempt: attempt,
      due_at_ms: System.monotonic_time(:millisecond) + delay,
      timer: timer,
      error: error
    }

    %{
      state
      | retry_attempts: Map.put(state.retry_attempts, issue_id, entry),
        claimed: MapSet.put(state.claimed, issue_id)
    }
    |> log_event("retry_scheduled", identifier, %{
      issue_id: issue_id,
      attempt: attempt,
      error: error,
      delay_ms: delay
    })
  end

  defp retry_delay_ms(attempt, max_backoff) do
    base = 10_000
    exponential = base * :math.pow(2, max(attempt - 1, 0))
    delay = trunc(min(exponential, max_backoff))
    max(1000, delay)
  end

  defp reconcile_running(state) do
    ids = Map.keys(state.running)

    if ids == [] do
      state
    else
      case Tracker.fetch_states_by_ids(state.config, ids) do
        {:ok, refreshed} ->
          map = Enum.into(refreshed, %{}, fn issue -> {issue.id, issue} end)

          Enum.reduce(ids, state, fn issue_id, acc ->
            case Map.get(map, issue_id) do
              nil ->
                acc

              issue ->
                normalized = Issue.normalize_state(issue.state)

                cond do
                  normalized in acc.config.tracker_terminal_states ->
                    stop_issue(acc, issue_id, true)

                  normalized in acc.config.tracker_active_states ->
                    updated = Map.put(acc.running[issue_id], :issue, issue)
                    %{acc | running: Map.put(acc.running, issue_id, updated)}

                  true ->
                    stop_issue(acc, issue_id, false)
                end
            end
          end)

        {:error, _} ->
          state
      end
    end
  end

  defp reconcile_stalled_runs(state) do
    base_timeout = state.config.stall_timeout_ms

    if base_timeout <= 0 do
      state
    else
      now = System.monotonic_time(:millisecond)

      Enum.reduce(state.running, state, fn {issue_id, entry}, acc ->
        last = entry.last_codex_timestamp
        timeout = stall_timeout_for_entry(entry, base_timeout)

        if is_integer(last) and now - last > timeout do
          stop_issue(acc, issue_id, false, "stalled")
        else
          acc
        end
      end)
    end
  end

  defp reconcile_review_handoffs(state) do
    pending =
      state.recent_runs
      |> Enum.reduce(%{}, fn run, acc ->
        case pending_review_artifact(run) do
          nil -> acc
          artifact -> Map.put_new(acc, run.issue_id, %{run: run, artifact: artifact})
        end
      end)

    issue_ids = Map.keys(pending)

    if issue_ids == [] do
      state
    else
      case Tracker.fetch_states_by_ids(state.config, issue_ids) do
        {:ok, issues} ->
          issue_map = Map.new(issues, &{&1.id, &1})

          Enum.reduce(pending, state, fn {issue_id, %{run: run, artifact: artifact}}, acc ->
            case Map.get(issue_map, issue_id) do
              nil ->
                acc

              issue ->
                acc
                |> maybe_clear_handoff_pending(issue)
                |> maybe_handle_review_transition(run, artifact, issue)
            end
          end)

        {:error, _} ->
          state
      end
    end
  end

  defp merge_review_handoff_now(state, issue_identifier, opts) do
    force_done? = Keyword.get(opts, :force_done, false)

    case Tracker.fetch_issue_by_identifier(state.config, issue_identifier) do
      {:ok, %Issue{} = issue} ->
        if force_done? or Issue.normalize_state(issue.state) == "done" do
          case retry_merge_review_handoff(state, issue_identifier, issue) do
            {:ok, next_state} ->
              {{:ok, :merged_or_attempted}, next_state}

            {:error, reason, next_state} ->
              next_state =
                log_event(next_state, "review_merge_handoff_failed", issue.identifier, %{
                  issue_id: issue.id,
                  reason: inspect(reason),
                  force_done: force_done?
                })

              {{:error, reason}, next_state}
          end
        else
          {{:error, :issue_not_done}, state}
        end

      {:ok, nil} ->
        {{:error, :issue_not_found}, state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp pending_review_artifact_for_issue(state, issue_id) do
    state.recent_runs
    |> Enum.find_value(fn run ->
      if run.issue_id == issue_id, do: pending_review_artifact(run), else: nil
    end)
  end

  defp lookup_review_artifact_for_issue(state, issue_identifier) do
    repo_slug =
      state.config.github_webhook_repo ||
        github_repo_slug_from_config(state.config)

    with repo_slug when is_binary(repo_slug) <- repo_slug,
         {:ok, artifact} <- GitReview.find_open_review_pr(repo_slug, issue_identifier) do
      artifact
      |> Map.put(:workspace_path, state.config.workspace_root || File.cwd!())
    else
      _ -> nil
    end
  end

  defp maybe_handle_review_transition(state, run, artifact, issue) do
    case Issue.normalize_state(issue.state) do
      "done" ->
        case do_merge_review_pr_for_done(state, run, artifact, issue) do
          {:ok, next_state} -> next_state
          {:error, _reason, next_state} -> next_state
        end

      _ ->
        state
    end
  end

  defp maybe_clear_handoff_pending(state, issue) do
    normalized = Issue.normalize_state(issue.state)

    cond do
      not Map.has_key?(state.handoff_pending, issue.id) ->
        state

      normalized in ["in review", "review"] ->
        state

      normalized not in state.config.tracker_active_states ->
        %{state | handoff_pending: Map.delete(state.handoff_pending, issue.id)}

      not handoff_pending?(state, issue.id) ->
        %{state | handoff_pending: Map.delete(state.handoff_pending, issue.id)}

      true ->
        state
    end
  end

  defp handoff_pending?(state, issue_id) do
    case Map.get(state.handoff_pending, issue_id) do
      started_at when is_integer(started_at) ->
        System.monotonic_time(:millisecond) - started_at < @handoff_pending_ttl_ms

      _ ->
        false
    end
  end

  defp merge_review_pr_for_done(state, run, artifact, issue) do
    case do_merge_review_pr_for_done(state, run, artifact, issue) do
      {:ok, next_state} -> next_state
      {:error, _reason, next_state} -> next_state
    end
  end

  defp do_merge_review_pr_for_done(state, run, artifact, issue) do
    case GitReview.merge_review_pr(run.workspace_path, artifact) do
      {:ok, merged_artifact} ->
        state =
          state
          |> update_recent_run_artifact(issue.id, merged_artifact)
          |> log_event("review_pr_merged_from_done", issue.identifier, %{
            issue_id: issue.id,
            pr_number: merged_artifact[:pr_number] || merged_artifact["pr_number"],
            pr_url: merged_artifact[:pr_url] || merged_artifact["pr_url"]
          })

        case Tracker.publish_review_handoff(state.config, issue, merged_artifact) do
          {:ok, republished_artifact} ->
            {:ok, update_recent_run_artifact(state, issue.id, republished_artifact)}

          _ ->
            {:ok, state}
        end

      {:error, reason} ->
        next_state =
          log_event(state, "review_pr_merge_failed_from_done", issue.identifier, %{
            issue_id: issue.id,
            reason: inspect(reason),
            pr_number: artifact[:pr_number] || artifact["pr_number"],
            pr_url: artifact[:pr_url] || artifact["pr_url"]
          })

        {:error, reason, next_state}
    end
  end

  defp retry_merge_review_handoff(state, issue_identifier, issue, attempts \\ 8)

  defp retry_merge_review_handoff(state, issue_identifier, issue, attempts) when attempts > 0 do
    artifact =
      pending_review_artifact_for_issue(state, issue.id) ||
        lookup_review_artifact_for_issue(state, issue_identifier)

    case artifact do
      nil ->
        Process.sleep(250)
        retry_merge_review_handoff(state, issue_identifier, issue, attempts - 1)

      artifact ->
        case do_merge_review_pr_for_done(
               state,
               %{workspace_path: artifact[:workspace_path] || artifact["workspace_path"]},
               artifact,
               issue
             ) do
          {:ok, next_state} ->
            {:ok, next_state}

          {:error, _reason, next_state} ->
            Process.sleep(250)
            retry_merge_review_handoff(next_state, issue_identifier, issue, attempts - 1)
        end
    end
  end

  defp retry_merge_review_handoff(state, _issue_identifier, _issue, 0) do
    {:error, :review_pr_not_found, state}
  end

  defp stall_timeout_for_entry(entry, base_timeout) do
    type = to_string(entry.last_update_type || "")

    cond do
      type == "demo_capture_started" ->
        max(base_timeout * 4, 180_000)

      type == "demo_capture_repair_requested" ->
        max(base_timeout * 2, 120_000)

      String.starts_with?(type, "demo_capture_") ->
        max(base_timeout * 2, 120_000)

      true ->
        base_timeout
    end
  end

  defp stop_issue(state, issue_id, cleanup, reason \\ "") do
    case Map.get(state.running, issue_id) do
      nil ->
        state

      entry ->
        state = remove_running(state, issue_id)
        state =
          log_event(state, "issue_stopped", entry.issue_identifier, %{
            issue_id: issue_id,
            cleanup: cleanup,
            reason: reason
          })

        if cleanup do
          WorkspaceManager.cleanup_workspace(
            entry.workspace_path,
            state.config.workspace_root,
            hook_map(state.config),
            state.config.hooks_timeout_ms
          )
        end

        if reason == "" do
          state
        else
          attempt = (entry.retry_attempt || 0) + 1
          schedule_retry(state, issue_id, entry.issue_identifier, attempt, reason)
        end
    end
  end

  defp cancel_running_issue(state, issue_id) do
    case Map.get(state.running, issue_id) do
      nil ->
        state

      entry ->
        recent_run = %{
          issue_id: entry.issue.id,
          identifier: entry.issue_identifier,
          outcome: "cancelled",
          completed_at_ms: System.system_time(:millisecond),
          attempt: entry.retry_attempt,
          error: "cancelled_by_operator",
          artifacts: [],
          issue: summarize_issue(entry.issue),
          routing: summarize_routing(entry.routing),
          workspace_path: entry.workspace_path,
          session_id: entry.session_id
        }

        existing = Map.get(state.retry_attempts, issue_id)
        if existing && Map.has_key?(existing, :timer), do: Process.cancel_timer(existing.timer)

        state = remove_running(state, issue_id)

        %{
          state
          | retry_attempts: Map.delete(state.retry_attempts, issue_id),
            recent_runs: prepend_recent_run(state.recent_runs, recent_run)
        }
        |> log_event("issue_cancelled", entry.issue_identifier, %{issue_id: issue_id})
      end
  end

  defp workspace_path(identifier, root) do
    WorkspaceManager.workspace_for_issue(identifier, root).path
  end

  defp running_count_for_state(state, normalized_state) do
    state.running
    |> Map.values()
    |> Enum.count(fn entry -> Issue.normalize_state(entry.issue.state) == normalized_state end)
  end

  defp hook_map(config) do
    %{
      after_create: config.hooks_after_create,
      before_run: config.hooks_before_run,
      after_run: config.hooks_after_run,
      before_remove: config.hooks_before_remove
    }
  end

  defp schedule_heartbeat(interval_ms) do
    Process.send_after(self(), :heartbeat, interval_ms)
  end

  defp schedule_reconcile(_interval_ms, false), do: :ok

  defp schedule_reconcile(interval_ms, true) do
    Process.send_after(self(), :reconcile, interval_ms)
  end

  defp maybe_sync_placeholder_workpad(state, issue, workspace_path) do
    body = PlanContract.render_planning_placeholder(issue.title)
    state =
      log_event(state, "workpad_placeholder_started", issue.identifier, %{
        issue_id: issue.id
      })
    started_at = System.monotonic_time(:millisecond)
    preferred_comment_id = read_workpad_comment_id(workspace_path)

    case Tracker.upsert_workpad(state.config, issue, body, preferred_comment_id) do
      {:ok, workpad} ->
        persist_workpad_comment_id(workspace_path, workpad[:comment_id])

        log_event(state, "workpad_placeholder_synced", issue.identifier, %{
          issue_id: issue.id,
          comment_id: workpad[:comment_id],
          action: workpad[:action],
          elapsed_ms: System.monotonic_time(:millisecond) - started_at
        })

      {:error, :rate_limited} ->
        log_event(state, "workpad_placeholder_deferred", issue.identifier, %{
          issue_id: issue.id,
          reason: ":rate_limited",
          elapsed_ms: System.monotonic_time(:millisecond) - started_at
        })

      {:error, reason} ->
        log_event(state, "workpad_placeholder_failed", issue.identifier, %{
          issue_id: issue.id,
          reason: inspect(reason),
          elapsed_ms: System.monotonic_time(:millisecond) - started_at
        })
    end
  end

  defp read_workpad_comment_id(workspace_path) when is_binary(workspace_path) do
    path = Path.join(workspace_path, ".git/symphony/workpad-comment-id")

    case File.read(path) do
      {:ok, raw} ->
        case String.trim(raw) do
          "" -> nil
          value -> value
        end

      _ ->
        nil
    end
  end

  defp persist_workpad_comment_id(workspace_path, comment_id)
       when is_binary(workspace_path) and is_binary(comment_id) and comment_id != "" do
    path = Path.join(workspace_path, ".git/symphony/workpad-comment-id")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, comment_id <> "\n")
    :ok
  end

  defp persist_workpad_comment_id(_, _), do: :ok

  defp status_payload(state) do
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

  defp maybe_resume_from_rate_limit_pause(%{paused: true, paused_reason: "linear_rate_limit"} = state) do
    if is_integer(state.paused_until_ms) and System.system_time(:millisecond) >= state.paused_until_ms do
      state
      |> Map.put(:paused, false)
      |> Map.put(:paused_reason, nil)
      |> Map.put(:paused_until_ms, nil)
      |> log_event("scheduler_resumed", nil, %{reason: "linear_rate_limit_reset"})
    else
      state
    end
  end

  defp maybe_resume_from_rate_limit_pause(state), do: state

  defp pause_for_rate_limit(state, reset_ms, context) do
    state
    |> Map.put(:paused, true)
    |> Map.put(:paused_reason, "linear_rate_limit")
    |> Map.put(:paused_until_ms, reset_ms)
    |> log_event("scheduler_paused", nil, %{
      reason: "linear_rate_limit",
      context: context,
      reset_ms: reset_ms
    })
  end

  defp rate_limit_reset_ms({:rate_limited, reset_ms}) when is_integer(reset_ms), do: reset_ms
  defp rate_limit_reset_ms({:error, {:rate_limited, reset_ms}}) when is_integer(reset_ms), do: reset_ms
  defp rate_limit_reset_ms(_), do: nil

  defp issue_status_payload(state, issue_identifier) do
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

  defp summarize_running(running) do
    running
    |> Enum.map(fn {_issue_id, entry} -> summarize_running_entry(entry) end)
  end

  defp summarize_retries(retry_attempts) do
    retry_attempts
    |> Enum.map(fn {_issue_id, retry} -> summarize_retry_entry(retry) end)
  end

  defp summarize_running_entry(entry) do
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

  defp summarize_retry_entry(retry) do
    %{
      issue_id: retry.issue_id,
      identifier: retry.identifier,
      attempt: retry.attempt,
      due_at_ms: retry.due_at_ms,
      error: retry.error
    }
  end

  defp summarize_recent_runs(recent_runs) do
    Enum.map(recent_runs, &summarize_recent_run/1)
  end

  defp summarize_recent_run(run) do
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

  defp pending_review_artifact(run) when is_map(run) do
    run.artifacts
    |> List.wrap()
    |> Enum.find(fn artifact ->
      kind = artifact[:kind] || artifact["kind"]
      pr_merged = artifact[:pr_merged] || artifact["pr_merged"]
      kind == "pull_request" and pr_merged != true
    end)
  end

  defp pending_review_artifact(_), do: nil

  defp summarize_config(config) do
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

  defp current_config_with_status_port(state) do
    if is_integer(state.status_port) and state.status_port > 0 do
      %{state.config | server_port: state.status_port}
    else
      state.config
    end
  end

  defp summarize_profiles(profiles) do
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

  defp build_recent_run(entry, result) do
    %{
      issue_id: entry.issue.id,
      identifier: entry.issue_identifier,
      outcome: result_outcome(result),
      completed_at_ms: System.system_time(:millisecond),
      attempt: entry.retry_attempt,
      error: result_error(result),
      artifacts: result_artifacts(result),
      issue: summarize_issue(entry.issue),
      routing: summarize_routing(entry.routing),
      workspace_path: entry.workspace_path,
      session_id: entry.session_id
    }
  end

  defp prepend_recent_run(recent_runs, recent_run) do
    [recent_run | recent_runs]
    |> Enum.take(20)
  end

  defp update_recent_run_artifact(state, issue_id, updated_artifact) do
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

  defp maybe_apply_runtime_update(entry, payload) do
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

  defp apply_phase_event(entry, type, details) do
    now = System.monotonic_time(:millisecond)

    case type do
      "workspace_setup_started" ->
        {Map.put(entry, :phase, "workspace_setup") |> Map.put(:phase_started_at_ms, now), details}

      "workspace_setup_finished" ->
        details = maybe_put_phase_elapsed(details, entry)
        {Map.put(entry, :phase, "planning") |> Map.put(:phase_started_at_ms, now), details}

      "workspace_setup_failed" ->
        {entry, maybe_put_phase_elapsed(details, entry)}

      "planning_turn_started" ->
        {Map.put(entry, :phase, "planning") |> Map.put(:phase_started_at_ms, now), details}

      "planning_turn_finished" ->
        details = maybe_put_phase_elapsed(details, entry)
        {Map.put(entry, :phase, "execution") |> Map.put(:phase_started_at_ms, now), details}

      "planning_turn_failed" ->
        {entry, maybe_put_phase_elapsed(details, entry)}

      "demo_capture_started" ->
        {Map.put(entry, :phase, "demo") |> Map.put(:phase_started_at_ms, now), details}

      "demo_capture_succeeded" ->
        details = maybe_put_phase_elapsed(details, entry)
        {Map.put(entry, :phase, "review_handoff") |> Map.put(:phase_started_at_ms, now), details}

      "demo_capture_skipped" ->
        details = maybe_put_phase_elapsed(details, entry)
        {Map.put(entry, :phase, "review_handoff") |> Map.put(:phase_started_at_ms, now), details}

      "demo_capture_failed" ->
        {entry, maybe_put_phase_elapsed(details, entry)}

      "workpad_synced" ->
        {entry, Map.put_new(details, "phase", entry.phase)}

      _ ->
        {entry, details}
    end
  end

  defp maybe_put_phase_elapsed(details, entry) do
    if is_integer(entry[:phase_started_at_ms]) do
      Map.put_new(details, "elapsed_ms", System.monotonic_time(:millisecond) - entry.phase_started_at_ms)
    else
      details
    end
  end

  defp summarize_routing(nil), do: nil

  defp summarize_routing(routing) when is_map(routing) do
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

  defp summarize_issue(issue) when is_struct(issue, Issue) do
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

  defp summarize_issue(_), do: nil

  defp summarize_demo(artifacts) when is_list(artifacts) do
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

  defp summarize_demo(_), do: nil

  defp summarize_assertion_failure(result) do
    %{
      type: result[:type] || result["type"],
      selector: result[:selector] || result["selector"],
      value: result[:value] || result["value"],
      actual: result[:actual] || result["actual"],
      actual_url: result[:actual_url] || result["actual_url"],
      actual_present: result[:actual_present] || result["actual_present"]
    }
  end

  defp summarize_events(events), do: Enum.map(events, &summarize_event/1)

  defp summarize_issue_events(events, issue_identifier) do
    events
    |> Enum.filter(&(&1.issue_identifier == issue_identifier))
    |> summarize_events()
  end

  defp summarize_event(event) do
    %{
      type: event.type,
      timestamp_ms: event.timestamp_ms,
      issue_identifier: event.issue_identifier,
      details: event.details
    }
  end

  defp log_event(state, type, issue_identifier, details) do
    event = %{
      type: type,
      timestamp_ms: System.system_time(:millisecond),
      issue_identifier: issue_identifier,
      details: details
    }

    maybe_log_runtime_event(event)

    %{state | events: [event | state.events] |> Enum.take(200)}
  end

  defp maybe_log_runtime_event(event) do
    case format_runtime_event(event) do
      nil -> :ok
      line -> Logger.info(line)
    end
  end

  defp format_runtime_event(%{type: type, issue_identifier: issue, details: details}) do
    prefix =
      case issue do
        nil -> "[symphony]"
        value -> "[#{value}]"
      end

    case type do
      "issue_dispatched" ->
        "#{prefix} dispatched (attempt #{details[:attempt] || details["attempt"] || 1})"

      "tracker_marked_started" ->
        "#{prefix} moved to In Progress#{format_elapsed(details)}"

      "tracker_mark_started_started" ->
        "#{prefix} marking In Progress"

      "tracker_mark_started_failed" ->
        "#{prefix} failed to mark In Progress#{format_elapsed(details)}: #{details[:reason] || details["reason"]}"

      "workpad_placeholder_started" ->
        "#{prefix} posting plan placeholder"

      "workpad_placeholder_synced" ->
        "#{prefix} plan placeholder posted#{format_elapsed(details)}"

      "workpad_placeholder_deferred" ->
        "#{prefix} plan placeholder deferred#{format_elapsed(details)}: #{details[:reason] || details["reason"]}"

      "workpad_placeholder_failed" ->
        "#{prefix} plan placeholder failed#{format_elapsed(details)}: #{details[:reason] || details["reason"]}"

      "workspace_setup_started" ->
        "#{prefix} workspace setup started"

      "workspace_setup_finished" ->
        "#{prefix} workspace setup finished#{format_elapsed(details)}"

      "workspace_setup_failed" ->
        "#{prefix} workspace setup failed: #{details[:reason] || details["reason"]}"

      "planning_turn_started" ->
        "#{prefix} planning started"

      "planning_turn_finished" ->
        "#{prefix} planning finished#{format_elapsed(details)}"

      "planning_turn_failed" ->
        "#{prefix} planning failed#{format_elapsed(details)}: #{details[:reason] || details["reason"]}"

      "workpad_synced" ->
        action = details[:action] || details["action"]
        suffix = if action, do: " (#{action})", else: ""
        "#{prefix} plan synced#{suffix}#{format_elapsed(details)}"

      "issue_refresh_started" ->
        "#{prefix} refreshing issue"

      "issue_refresh_finished" ->
        "#{prefix} issue refreshed#{format_elapsed(details)}"

      "issue_refresh_failed" ->
        "#{prefix} issue refresh failed#{format_elapsed(details)}: #{details[:reason] || details["reason"]}"

      "execution_turn_started" ->
        "#{prefix} execution started"

      "execution_turn_finished" ->
        "#{prefix} execution finished#{format_elapsed(details)}"

      "execution_turn_failed" ->
        "#{prefix} execution failed#{format_elapsed(details)}: #{details[:reason] || details["reason"]}"

      "routing_selected" ->
        "#{prefix} routed to #{details[:provider] || details["provider"]}/#{details[:model] || details["model"]}"

      "session_started" ->
        "#{prefix} model session started"

      "demo_capture_started" ->
        "#{prefix} demo capture started"

      "demo_capture_repair_requested" ->
        "#{prefix} demo plan repair requested"

      "demo_capture_succeeded" ->
        "#{prefix} demo capture succeeded#{format_elapsed(details)}"

      "demo_capture_skipped" ->
        "#{prefix} demo capture skipped"

      "demo_capture_failed" ->
        "#{prefix} demo capture failed#{format_elapsed(details)}: #{details[:reason] || details["reason"]}"

      "run_finished" ->
        "#{prefix} run finished (#{details[:outcome] || details["outcome"]})"

      "run_failed" ->
        "#{prefix} run failed: #{details[:reason] || details["reason"]}"

      "tracker_marked_in_review" ->
        "#{prefix} moved to In Review"

      "tracker_marked_done" ->
        "#{prefix} moved to Done"

      "review_pr_merged_from_done" ->
        "#{prefix} merged review PR"

      "clarification_requested" ->
        "#{prefix} clarification requested"

      "retry_scheduled" ->
        "#{prefix} retry scheduled"

      _ ->
        nil
    end
  end

  defp format_elapsed(details) do
    value = details[:elapsed_ms] || details["elapsed_ms"]

    if is_integer(value) and value >= 0 do
      " in #{Float.round(value / 1000, 1)}s"
    else
      ""
    end
  end

  defp issue_lookup(state, issue_identifier) do
    issue_identifier = String.trim(issue_identifier)

    running =
      state.running
      |> Map.values()
      |> Enum.find(fn entry -> entry.issue_identifier == issue_identifier end)

    retry =
      state.retry_attempts
      |> Map.values()
      |> Enum.find(fn entry -> entry.identifier == issue_identifier end)

    recent =
      state.recent_runs
      |> Enum.find(fn run -> run.identifier == issue_identifier end)

    cond do
      running -> %{issue_id: running.issue.id, identifier: running.issue_identifier}
      retry -> %{issue_id: retry.issue_id, identifier: retry.identifier}
      recent -> %{issue_id: recent.issue_id, identifier: recent.identifier}
      true -> nil
    end
  end

  defp running_issue_id(state, issue_identifier) do
    state.running
    |> Map.values()
    |> Enum.find_value(fn entry -> if entry.issue_identifier == issue_identifier, do: entry.issue.id end)
  end

  defp clarification_requested?({:clarification_requested, _}), do: true
  defp clarification_requested?(_), do: false

  defp non_retryable_failure?({:demo_plan_invalid, _}), do: true
  defp non_retryable_failure?({:recording_capture_failed, _}), do: true
  defp non_retryable_failure?({:recording_setup_failed, _}), do: true
  defp non_retryable_failure?(:recording_setup_command_missing), do: true
  defp non_retryable_failure?(_), do: false

  defp github_repo_slug_from_config(config) do
    config.github_webhook_repo || parse_repo_slug(System.get_env("GITHUB_REPO_URL"))
  end

  defp parse_repo_slug(nil), do: nil

  defp parse_repo_slug(url) when is_binary(url) do
    normalized =
      url
      |> String.trim()
      |> String.replace_suffix(".git", "")

    cond do
      Regex.match?(~r{^https://github\.com/[^/]+/[^/]+$}, normalized) ->
        [_, owner, repo] = Regex.run(~r{^https://github\.com/([^/]+)/([^/]+)$}, normalized)
        "#{owner}/#{repo}"

      Regex.match?(~r{^git@github\.com:[^/]+/[^/]+$}, normalized) ->
        [_, owner, repo] = Regex.run(~r{^git@github\.com:([^/]+)/([^/]+)$}, normalized)
        "#{owner}/#{repo}"

      true ->
        nil
    end
  end
end
