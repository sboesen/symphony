defmodule Symphony.OrchestratorStatusTest do
  use ExUnit.Case, async: true

  alias Symphony.{Issue, OrchestratorStatus}

  test "status_payload and issue_status_payload summarize running retry and recent runs" do
    issue = %Issue{id: "1", identifier: "TEST-1", title: "Title", state: "In Progress", url: "https://linear.app/issue/1"}
    running = %{"1" => %{issue: issue, issue_identifier: "TEST-1", started_at: 11, retry_attempt: 2, workspace_path: "/tmp/ws", routing: %{provider: "openai", model: "gpt-5"}, session_id: "s1", thread_id: "t1", turn_id: "u1", last_update_type: "planning_turn_started", codex_total_tokens: 42, last_codex_timestamp: 99}}
    retries = %{"2" => %{issue_id: "2", identifier: "TEST-2", attempt: 3, due_at_ms: 44, error: "boom"}}
    recent_run = %{issue_id: "3", identifier: "TEST-3", outcome: "completed", completed_at_ms: 55, attempt: 1, error: nil, artifacts: [], issue: %{id: "3"}, routing: nil, workspace_path: "/tmp/3", session_id: "s3"}

    state = %{
      workflow_path: "WORKFLOW.md",
      poll_enabled: true,
      workflow_mtime_ms: 1,
      poll_interval_ms: 2,
      paused: false,
      paused_reason: nil,
      paused_until_ms: nil,
      running: running,
      retry_attempts: retries,
      claimed: MapSet.new(["1"]),
      completed: MapSet.new(["3"]),
      last_candidates: [%{identifier: "TEST-4"}],
      recent_runs: [recent_run],
      events: [%{type: "event", timestamp_ms: 66, issue_identifier: "TEST-1", details: %{}}],
      codex_totals: %{total_tokens: 99},
      status_port: 4040,
      config: %{tracker_kind: "mock", tracker_project_slug: nil, poll_enabled: true, poll_interval_ms: 2, max_concurrent_agents: 1, workspace_root: "/tmp", server_port: 4000, codex_command: "codex", codex_router_enabled: false, codex_router_default_provider: nil, codex_router_hard_provider: nil, codex_router_model: nil, codex_router_hard_model: nil, codex_router_hard_percentile: nil, codex_profiles: %{}, recording_enabled: false, recording_url: nil, recording_output_dir: nil, recording_publish_to_tracker: false, recording_publish_comment: false, review_pr_enabled: false, review_required: false, review_pr_draft: false, review_pr_base_branch: "main", review_pr_auto_merge: false, github_webhook_auto_register: false, github_webhook_provider: nil, github_webhook_repo: nil, linear_webhook_auto_register: false}
    }

    payload = OrchestratorStatus.status_payload(state)
    assert payload.running_count == 1
    assert hd(payload.running).identifier == "TEST-1"
    assert hd(payload.retries).identifier == "TEST-2"
    assert hd(payload.recent_runs).identifier == "TEST-3"
    assert payload.config.server_port == 4000

    assert OrchestratorStatus.issue_status_payload(state, " TEST-1 ").status == "running"
    assert OrchestratorStatus.issue_status_payload(state, "TEST-2").status == "retrying"
    assert OrchestratorStatus.issue_status_payload(state, "TEST-3").status == "completed"
    assert OrchestratorStatus.issue_status_payload(state, "missing") == nil
  end

  test "current_config_with_status_port overrides server port only when present" do
    state = %{status_port: 5050, config: %{server_port: 4000}}
    assert OrchestratorStatus.current_config_with_status_port(state).server_port == 5050
    assert OrchestratorStatus.current_config_with_status_port(%{status_port: nil, config: %{server_port: 4000}}).server_port == 4000
  end

  test "build_recent_run update_recent_run_artifact and pending_review_artifact handle review PRs" do
    issue = %Issue{id: "1", identifier: "TEST-1", title: "Title", state: "Done", url: "url"}
    entry = %{issue: issue, issue_identifier: "TEST-1", retry_attempt: 2, routing: %{provider: "openai"}, workspace_path: "/tmp/ws", session_id: "s1"}
    artifact = %{kind: "pull_request", pr_number: 7, repo_slug: "acme/repo", pr_merged: false}

    run =
      OrchestratorStatus.build_recent_run(
        entry,
        {:ok, %{artifacts: [artifact]}},
        123
      )

    assert run.outcome == "completed"
    assert run.completed_at_ms == 123
    assert OrchestratorStatus.pending_review_artifact(run) == artifact

    state = %{recent_runs: [run]}
    updated = %{artifact | pr_merged: true}
    state = OrchestratorStatus.update_recent_run_artifact(state, "1", updated)
    assert hd(state.recent_runs).artifacts == [updated]
    assert OrchestratorStatus.prepend_recent_run(Enum.to_list(1..25), :new) |> length() == 20
  end

  test "maybe_apply_runtime_update and apply_phase_event update routing sessions and elapsed time" do
    entry = %{session_id: nil, thread_id: nil, turn_id: nil, routing: nil, phase: "workspace_setup", phase_started_at_ms: 100}

    updated =
      OrchestratorStatus.maybe_apply_runtime_update(entry, %{
        type: :routing,
        routing: %{provider: "openai", model: "gpt-5"},
        session_id: "s1",
        thread_id: "t1",
        turn_id: "u1"
      })

    assert updated.routing.provider == "openai"
    assert updated.last_update_type == :routing
    assert updated.session_id == "s1"

    {next_entry, details} =
      OrchestratorStatus.apply_phase_event(updated, "workspace_setup_finished", %{}, 150)

    assert next_entry.phase == "planning"
    assert next_entry.phase_started_at_ms == 150
    assert details["elapsed_ms"] == 50

    {same_entry, workpad_details} =
      OrchestratorStatus.apply_phase_event(%{updated | phase: "execution"}, "workpad_synced", %{}, 200)

    assert same_entry.phase == "execution"
    assert workpad_details["phase"] == "execution"
  end

  test "summarize_demo extracts assertion failures and summarize_profiles reports secret presence" do
    artifact = %{
      kind: "video_recording",
      status: "published",
      verification: %{
        results: [
          %{passed: true, type: "text"},
          %{passed: false, type: "selector", selector: "#app", actual: "missing"}
        ]
      },
      video_path: "/tmp/demo.mp4",
      published: true
    }

    demo = OrchestratorStatus.summarize_demo([artifact])
    assert demo.assertion_count == 2
    assert demo.assertion_failures == 1
    assert demo.failed_assertions == [%{type: "selector", selector: "#app", value: nil, actual: "missing", actual_url: nil, actual_present: nil}]

    profiles =
      OrchestratorStatus.summarize_profiles(%{
        default: %{name: "default", api_key: "key", z_api_key: nil, env: %{"A" => "1"}}
      })

    assert profiles.default.has_api_key == true
    assert profiles.default.has_z_api_key == false
    assert profiles.default.env_keys == ["A"]
  end
end
