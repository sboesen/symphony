defmodule Symphony.OrchestratorTest do
  use ExUnit.Case, async: false

  setup do
    orchestrator = Process.whereis(Symphony.Orchestrator)
    original = :sys.get_state(orchestrator)

    on_exit(fn ->
      :sys.replace_state(orchestrator, fn _ -> original end)
    end)

    %{orchestrator: orchestrator, original: original}
  end

  test "status exposes current runtime summary", %{orchestrator: orchestrator, original: original} do
    running_entry = running_entry("TEST-1")
    retry_entry = retry_entry("TEST-2")
    recent_run = recent_run("TEST-3", "completed")

    :sys.replace_state(orchestrator, fn _ ->
      %{
        original
        | paused: true,
          paused_reason: "manual",
          paused_until_ms: 123,
          running: %{"issue-1" => running_entry},
          retry_attempts: %{"issue-2" => retry_entry},
          claimed: MapSet.new(["issue-1"]),
          completed: MapSet.new(["issue-3"]),
          last_candidates: [%{identifier: "TEST-4"}],
          recent_runs: [recent_run],
          events: [%{type: "event", issue_identifier: "TEST-1", timestamp_ms: 1, details: %{}}],
          codex_totals: %{input_tokens: 1, output_tokens: 2, total_tokens: 3, seconds_running: 4.0}
      }
    end)

    payload = Symphony.Orchestrator.status()

    assert payload.paused == true
    assert payload.paused_reason == "manual"
    assert payload.running_count == 1
    assert payload.retry_count == 1
    assert payload.claimed_count == 1
    assert payload.completed_count == 1
    assert payload.candidate_count == 1
    assert hd(payload.running).identifier == "TEST-1"
    assert hd(payload.retries).identifier == "TEST-2"
    assert hd(payload.recent_runs).identifier == "TEST-3"
    assert hd(payload.events).type == "event"
    assert payload.codex_totals.total_tokens == 3
  end

  test "issue_status reports running, retrying, recent, and missing issues", %{
    orchestrator: orchestrator,
    original: original
  } do
    :sys.replace_state(orchestrator, fn _ ->
      %{
        original
        | running: %{"issue-1" => running_entry("TEST-1")},
          retry_attempts: %{"issue-2" => retry_entry("TEST-2")},
          recent_runs: [recent_run("TEST-3", "failed")],
          events: [
            %{type: "run_finished", issue_identifier: "TEST-1", timestamp_ms: 1, details: %{}},
            %{type: "retry", issue_identifier: "TEST-2", timestamp_ms: 2, details: %{}},
            %{type: "done", issue_identifier: "TEST-3", timestamp_ms: 3, details: %{}}
          ]
      }
    end)

    assert Symphony.Orchestrator.issue_status("TEST-1").status == "running"
    assert Symphony.Orchestrator.issue_status("TEST-2").status == "retrying"
    assert Symphony.Orchestrator.issue_status("TEST-3").status == "failed"
    assert Symphony.Orchestrator.issue_status("MISSING") == nil
  end

  test "external_event appends events and pause/resume toggle scheduler state", %{
    orchestrator: orchestrator,
    original: original
  } do
    :sys.replace_state(orchestrator, fn _ -> %{original | events: []} end)

    assert :ok = Symphony.Orchestrator.external_event("github_ping", "TEST-1", %{ok: true})
    assert {:ok, %{paused: true}} = Symphony.Orchestrator.pause()

    paused_state = :sys.get_state(orchestrator)
    assert paused_state.paused == true
    assert paused_state.paused_reason == "manual"
    assert Enum.any?(paused_state.events, &(&1.type == "scheduler_paused"))
    assert Enum.any?(paused_state.events, &(&1.type == "github_ping"))

    assert {:ok, %{paused: false}} = Symphony.Orchestrator.resume()
    resumed_state = :sys.get_state(orchestrator)
    assert resumed_state.paused == false
    assert resumed_state.paused_reason == nil
    assert Enum.any?(resumed_state.events, &(&1.type == "scheduler_resumed"))
  end

  test "retry_issue schedules known issues and rejects unknown ones", %{
    orchestrator: orchestrator,
    original: original
  } do
    :sys.replace_state(orchestrator, fn _ ->
      %{
        original
        | running: %{"issue-1" => running_entry("TEST-1")},
          retry_attempts: %{}
      }
    end)

    assert {:ok, %{issue_identifier: "TEST-1", scheduled: true}} =
             Symphony.Orchestrator.retry_issue("TEST-1")

    state = :sys.get_state(orchestrator)
    assert Map.has_key?(state.retry_attempts, "issue-1")
    assert {:error, :issue_not_found} = Symphony.Orchestrator.retry_issue("TEST-404")
  end

  test "cancel_issue removes running issues and records a cancelled recent run", %{
    orchestrator: orchestrator,
    original: original
  } do
    :sys.replace_state(orchestrator, fn _ ->
      %{
        original
        | running: %{"issue-1" => running_entry("TEST-1")},
          retry_attempts: %{
            "issue-1" => %{issue_id: "issue-1", identifier: "TEST-1", attempt: 2, due_at_ms: 123, error: "old", timer: make_ref()}
          },
          recent_runs: []
      }
    end)

    assert {:ok, %{issue_identifier: "TEST-1", cancelled: true}} =
             Symphony.Orchestrator.cancel_issue(" TEST-1 ")

    state = :sys.get_state(orchestrator)
    assert state.running == %{}
    refute Map.has_key?(state.retry_attempts, "issue-1")
    assert hd(state.recent_runs).outcome == "cancelled"
    assert hd(state.recent_runs).identifier == "TEST-1"

    assert {:error, :issue_not_running} = Symphony.Orchestrator.cancel_issue("TEST-404")
  end

  defp running_entry(identifier) do
    %{
      issue: %Symphony.Issue{
        id: "issue-1",
        identifier: identifier,
        title: "Issue #{identifier}",
        url: "https://linear.example/#{identifier}",
        state: "In Progress"
      },
      issue_identifier: identifier,
      started_at: 1,
      retry_attempt: 0,
      workspace_path: "/tmp/#{identifier}",
      routing: %{provider: "zai", model: "GLM-5"},
      session_id: "session-1",
      thread_id: "thread-1",
      turn_id: "turn-1",
      last_update_type: "codex_update",
      codex_total_tokens: 12,
      last_codex_timestamp: 2
    }
  end

  defp retry_entry(identifier) do
    %{issue_id: "issue-2", identifier: identifier, attempt: 2, due_at_ms: 999, error: "boom"}
  end

  defp recent_run(identifier, outcome) do
    %{
      issue_id: "issue-3",
      identifier: identifier,
      outcome: outcome,
      completed_at_ms: 3,
      attempt: 1,
      error: if(outcome == "failed", do: "boom", else: nil),
      artifacts: [],
      issue: %{identifier: identifier, title: "Recent #{identifier}"},
      routing: %{provider: "zai", model: "GLM-5"},
      workspace_path: "/tmp/#{identifier}",
      session_id: "session-3"
    }
  end
end
