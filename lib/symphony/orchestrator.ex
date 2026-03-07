defmodule Symphony.Orchestrator do
  @moduledoc "Long-running scheduler loop and authoritative dispatch state."

  use GenServer
  require Logger

  alias Symphony.{Workflow, Config, Tracker, WorkspaceManager, Issue}

  defstruct [
    :workflow_path,
    :workflow_mtime_ms,
    :config,
    :prompt_template,
    :poll_interval_ms,
    paused: false,
    running: %{},
    claimed: MapSet.new(),
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
         :ok <- Config.validate_dispatch(config) do
      state = %__MODULE__{
        workflow_path: workflow_path,
        workflow_mtime_ms: workflow.mtime_ms,
        config: config,
        prompt_template: workflow.prompt_template,
        poll_interval_ms: config.poll_interval_ms
      }

      _ = Symphony.StatusServer.ensure_started(config.server_port)
      state = log_event(state, "system_ready", nil, %{server_port: config.server_port})
      cleanup_startup_terminals(state)
      schedule_tick(0)
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
    {:reply, state.config, state}
  end

  def handle_call({:external_event, type, issue_identifier, details}, _from, state) do
    state = log_event(state, type, issue_identifier, details)
    {:reply, :ok, state}
  end

  def handle_call(:refresh, _from, state) do
    state =
      state
      |> log_event("manual_refresh_requested", nil, %{})
      |> dispatch_cycle()

    {:reply, {:ok, status_payload(state)}, state}
  end

  def handle_call(:pause, _from, state) do
    state = %{state | paused: true}
    state = log_event(state, "scheduler_paused", nil, %{})
    {:reply, {:ok, %{paused: true}}, state}
  end

  def handle_call(:resume, _from, state) do
    state = %{state | paused: false}
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

  def handle_info(:tick, state) do
    state = maybe_reload_workflow(state)
    state = reconcile_running(state)
    state = reconcile_stalled_runs(state)

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

    schedule_tick(state.poll_interval_ms)
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
              case Tracker.mark_in_review(state.config, issue_id) do
                :ok ->
                  log_event(state, "tracker_marked_in_review", entry.issue_identifier, %{
                    issue_id: issue_id
                  })

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

            {:error, payload} ->
              reason = error_reason(payload)
              attempt = max(1, entry.retry_attempt || 0)

              Logger.warning(
                "agent run failed for issue #{entry.issue_identifier} (attempt=#{attempt}): #{inspect(reason)}"
              )

              state
              |> log_event("run_failed", entry.issue_identifier, %{
                issue_id: issue_id,
                attempt: attempt,
                reason: inspect(reason)
              })
              |> schedule_retry(issue_id, entry.issue_identifier, attempt + 1, inspect(reason))
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
        updated_entry =
          entry
          |> Map.put(:last_codex_timestamp, System.monotonic_time(:millisecond))
          |> Map.put(:last_update_type, to_string(type))

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
        schedule_retry(
          state,
          retry_entry.issue_id,
          retry_entry.identifier,
          retry_entry.attempt + 1,
          inspect(reason)
        )
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
             :ok <- Config.validate_dispatch(config) do
          _ = Symphony.StatusServer.ensure_started(config.server_port)

          %{
            state
            | workflow_mtime_ms: workflow.mtime_ms,
              config: config,
              prompt_template: workflow.prompt_template,
              poll_interval_ms: config.poll_interval_ms
          }
          |> log_event("workflow_reloaded", nil, %{workflow_path: state.workflow_path})
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
        log_event(state, "candidate_poll_failed", nil, %{reason: inspect(reason)})
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

    task_fn = fn ->
      Symphony.AgentRunner.run(
        issue,
        attempt,
        state.config,
        state.prompt_template,
        orchestrator_pid
      )
    end

    case Task.Supervisor.start_child(Symphony.TaskSupervisor, task_fn) do
      {:ok, pid} ->
        state =
          log_event(state, "issue_dispatched", issue.identifier, %{
            issue_id: issue.id,
            attempt: dispatch_attempt
          })

        state =
          case Tracker.mark_started(state.config, issue.id) do
            :ok ->
              log_event(state, "tracker_marked_started", issue.identifier, %{issue_id: issue.id})

            {:error, reason} ->
              Logger.warning("failed to mark issue #{issue.identifier} started: #{inspect(reason)}")

              log_event(state, "tracker_mark_started_failed", issue.identifier, %{
                issue_id: issue.id,
                reason: inspect(reason)
              })
          end

        monitor = Process.monitor(pid)
        path = workspace_path(issue.identifier, state.config.workspace_root)

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

  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end

  defp status_payload(state) do
    %{
      workflow_path: state.workflow_path,
      workflow_mtime_ms: state.workflow_mtime_ms,
      poll_interval_ms: state.poll_interval_ms,
      paused: state.paused,
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
      config: summarize_config(state.config)
    }
  end

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

  defp summarize_config(config) do
    %{
      tracker_kind: config.tracker_kind,
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
      review_pr_draft: config.review_pr_draft,
      review_pr_base_branch: config.review_pr_base_branch,
      review_pr_auto_merge: config.review_pr_auto_merge,
      github_webhook_auto_register: config.github_webhook_auto_register,
      github_webhook_provider: config.github_webhook_provider,
      github_webhook_repo: config.github_webhook_repo
    }
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
    case Enum.find(artifacts, &(&1[:kind] == "video_recording" or &1["kind"] == "video_recording")) do
      nil ->
        nil

      artifact ->
        verification = artifact[:verification] || artifact["verification"] || %{}
        results = verification[:results] || verification["results"] || []
        failed_results =
          Enum.filter(results, fn result -> (result[:passed] || result["passed"]) != true end)

        %{
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

    %{state | events: [event | state.events] |> Enum.take(200)}
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
end
