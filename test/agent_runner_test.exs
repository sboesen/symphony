defmodule Symphony.AgentRunnerTest do
  use ExUnit.Case, async: false

  alias Symphony.AgentRunner

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-agent-runner-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    File.mkdir_p!(workspace_root)

    mock_file = Path.join(root, "mock_issues.json")
    write_mock_file!(mock_file, "In Progress")

    bin_dir = Path.join(root, "bin")
    File.mkdir_p!(bin_dir)
    opencode = Path.join(bin_dir, "opencode")
    node = Path.join(bin_dir, "node")
    original_path = System.get_env("PATH") || ""

    File.write!(
      opencode,
      """
      #!/usr/bin/env python3
      import json, os, pathlib, sys, time

      workspace = pathlib.Path.cwd()
      symphony_dir = workspace / ".git" / "symphony"
      symphony_dir.mkdir(parents=True, exist_ok=True)
      prompt = os.environ.get("SYMPHONY_PROMPT", "")
      mode = os.environ.get("FAKE_AGENT_MODE", "success")

      if "Create the execution plan" in prompt:
          plan = {
              "summary": "Plan",
              "steps": [
                  {"id": "1", "content": "Implement", "status": "pending"}
              ]
          }
          (symphony_dir / "plan.json").write_text(json.dumps(plan))
          if mode == "salvage_plan":
              time.sleep(2.0)
      else:
          if "work plan is out of date" in prompt and mode == "repair_plan_timeout":
              time.sleep(2.0)
              sys.exit(0)

          plan_status = "pending" if mode == "repair_plan_timeout" else "completed"
          plan = {
              "summary": "Plan",
              "steps": [
                  {"id": "1", "content": "Implement", "status": plan_status}
              ]
          }
          (symphony_dir / "plan.json").write_text(json.dumps(plan))

          if mode == "blocked":
              result = {
                  "status": "blocked",
                  "summary": "Need clarification",
                  "tests": [],
                  "artifacts": [],
                  "notes": "Missing API key"
              }
          elif mode == "needs_more_work":
              result = {
                  "status": "needs_more_work",
                  "summary": "Continue iterating",
                  "tests": [],
                  "artifacts": [],
                  "notes": None
              }
          elif mode == "salvage_completed":
              result = {
                  "status": "completed",
                  "summary": "Recovered from workspace",
                  "tests": [],
                  "artifacts": [],
                  "notes": None
              }
          else:
              result = {
                  "status": "completed",
                  "summary": "Done",
                  "tests": ["mix test"],
                  "artifacts": [],
                  "notes": None
              }

          (symphony_dir / "result.json").write_text(json.dumps(result))

      print(json.dumps({"type":"session.created","sessionID":"session_cli"}), flush=True)
      if (mode == "salvage_completed" and "Create the execution plan" not in prompt) or mode == "salvage_plan":
          time.sleep(2.0)
      else:
          print(json.dumps({"type":"step_finish","step":{"finishReason":"stop"}}), flush=True)
          time.sleep(0.1)
      """
    )

    File.chmod!(opencode, 0o755)

    File.write!(
      node,
      """
      #!/bin/bash
      output_dir=""
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "--output-dir" ]; then
          output_dir="$2"
          shift 2
        else
          shift
        fi
      done

      mkdir -p "$output_dir"
      cat > "$output_dir/manifest.json" <<'EOF'
      {"capture_type":"video","status":"ready","source_url":"file:///demo.html","output_dir":"OUT","video_path":"OUT/demo.webm","raw_video_path":"OUT/raw.webm","trace_path":"OUT/trace.zip","screenshot_path":"OUT/final.png","verification_path":"OUT/verify.json","assertions":[],"verification":{"ok":true},"console_errors":[]}
      EOF
      python3 - "$output_dir/manifest.json" "$output_dir" <<'PY'
      import pathlib, sys
      path = pathlib.Path(sys.argv[1])
      text = path.read_text()
      path.write_text(text.replace("OUT", sys.argv[2]))
      PY
      exit 0
      """
    )

    File.chmod!(node, 0o755)
    System.put_env("PATH", bin_dir <> ":" <> original_path)

    on_exit(fn ->
      System.delete_env("FAKE_AGENT_MODE")
      System.put_env("PATH", original_path)
      File.rm_rf!(root)
    end)

    File.write!(Path.join(root, "demo.html"), "<html><body>demo</body></html>")

    %{
      root: root,
      workspace_root: workspace_root,
      mock_file: mock_file,
      opencode: opencode,
      demo_html: Path.join(root, "demo.html")
    }
  end

  test "run completes successfully and reports artifacts payload", ctx do
    System.put_env("FAKE_AGENT_MODE", "success")

    issue = issue()
    config = base_config(ctx)

    AgentRunner.run(issue, 1, config, "Implement {{issue.identifier}}", self())

    assert_receive {:agent_runtime_event, "issue-1", "workspace_setup_started", %{attempt: 1}}
    assert_receive {:agent_runtime_event, "issue-1", "workspace_setup_finished", %{workspace_path: workspace_path}}
    assert_receive {:agent_runtime_event, "issue-1", "execution_turn_started", %{turn_index: 1}}
    assert_receive {:agent_runtime_event, "issue-1", "execution_turn_finished", %{turn_index: 1}}
    assert_receive {:agent_run_result, "issue-1", {:ok, %{artifacts: []}}}

    assert File.exists?(Path.join(workspace_path, ".git/symphony/plan.json"))
    assert File.exists?(Path.join(workspace_path, ".git/symphony/result.json"))
    assert File.exists?(Path.join(workspace_path, ".git/symphony/workpad-comment-id"))
  end

  test "run publishes clarification and returns an error for blocked turns", ctx do
    System.put_env("FAKE_AGENT_MODE", "blocked")

    issue = issue()
    config = base_config(ctx)

    AgentRunner.run(issue, 1, config, "Implement {{issue.identifier}}", self())

    assert_receive {:agent_runtime_event, "issue-1", "workspace_setup_finished", %{workspace_path: workspace_path}}
    assert_receive {:agent_runtime_event, "issue-1", "execution_turn_started", %{turn_index: 1}}
    assert_receive {:agent_runtime_event, "issue-1", "execution_turn_finished", %{turn_index: 1}}

    assert_receive {:agent_run_result, "issue-1", {:error, %{reason: {:clarification_requested, completion}, artifacts: []}}}
    assert completion.status == "blocked"
    assert completion.notes == "Missing API key"
    assert File.exists?(Path.join(workspace_path, ".git/symphony/clarification-comment-id"))
  end

  test "run returns max_turns_exceeded when more work is still needed on the last turn", ctx do
    System.put_env("FAKE_AGENT_MODE", "needs_more_work")

    config =
      base_config(ctx)
      |> Map.put(:max_turns, 1)

    AgentRunner.run(issue(), 1, config, "Implement {{issue.identifier}}", self())

    assert_receive {:agent_run_result, "issue-1", {:error, %{reason: {:max_turns_exceeded, completion}, artifacts: []}}}
    assert completion.status == "needs_more_work"
  end

  test "run rejects needs-more-work results when the refreshed issue is not active", ctx do
    System.put_env("FAKE_AGENT_MODE", "needs_more_work")
    write_mock_file!(ctx.mock_file, "Done")

    AgentRunner.run(issue(), 1, base_config(ctx), "Implement {{issue.identifier}}", self())

    assert_receive {:agent_run_result, "issue-1",
                    {:error,
                     %{reason: {:needs_more_work_but_issue_not_active, completion}, artifacts: []}}}

    assert completion.status == "needs_more_work"
  end

  test "run salvages a completed execution result from the workspace after timeout", ctx do
    System.put_env("FAKE_AGENT_MODE", "salvage_completed")

    config =
      base_config(ctx)
      |> Map.put(:turn_timeout_ms, 1_000)

    AgentRunner.run(issue(), 1, config, "Implement {{issue.identifier}}", self())

    assert_receive {:agent_runtime_event, "issue-1", "execution_turn_started", %{turn_index: 1}}
    assert_receive {:agent_runtime_event, "issue-1", "execution_turn_finished", %{turn_index: 1}}
    assert_receive {:agent_runtime_event, "issue-1", "run_salvaged_from_workspace", %{status: "completed"}}
    assert_receive {:agent_run_result, "issue-1", {:ok, %{artifacts: []}}}
  end

  test "run salvages the planning result from the workspace after timeout", ctx do
    System.put_env("FAKE_AGENT_MODE", "salvage_plan")

    config =
      base_config(ctx)
      |> Map.put(:turn_timeout_ms, 1_000)

    AgentRunner.run(issue(), 1, config, "Implement {{issue.identifier}}", self())

    assert_receive {:agent_runtime_event, "issue-1", "plan_salvaged_from_workspace", %{}}
    assert_receive {:agent_runtime_event, "issue-1", "execution_turn_started", %{turn_index: 1}}
    assert_receive {:agent_run_result, "issue-1", {:ok, %{artifacts: []}}}
  end

  test "run finalizes the workpad deterministically when plan repair times out", ctx do
    System.put_env("FAKE_AGENT_MODE", "repair_plan_timeout")

    config =
      base_config(ctx)
      |> Map.put(:turn_timeout_ms, 1_000)

    AgentRunner.run(issue(), 1, config, "Implement {{issue.identifier}}", self())

    assert_receive {:agent_runtime_event, "issue-1", "workpad_completed_deterministically", %{}}
    assert_receive {:agent_run_result, "issue-1", {:ok, %{artifacts: []}}}
  end

  test "run captures and returns demo artifacts when recording is enabled", ctx do
    System.put_env("FAKE_AGENT_MODE", "success")

    config =
      base_config(ctx)
      |> Map.put(:recording_enabled, true)
      |> Map.put(:recording_url, ctx.demo_html)
      |> Map.put(:recording_ready_timeout_ms, 1_000)
      |> Map.put(:recording_wait_ms, 0)
      |> Map.put(:recording_width, 1280)
      |> Map.put(:recording_height, 720)
      |> Map.put(:recording_trace, false)
      |> Map.put(:recording_publish_to_tracker, true)

    AgentRunner.run(issue(), 1, config, "Implement {{issue.identifier}}", self())

    assert_receive {:agent_runtime_event, "issue-1", "demo_capture_started", %{attempts_left: 2}}
    assert_receive {:agent_runtime_event, "issue-1", "demo_capture_succeeded", %{"status" => "ready"}}

    assert_receive {:agent_run_result, "issue-1", {:ok, %{artifacts: [artifact]}}}
    assert artifact.kind == "demo_artifact"
    assert artifact.status == "ready"
  end

  defp base_config(ctx) do
    %Symphony.Config{
      tracker_kind: "mock",
      tracker_mock_file: ctx.mock_file,
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done"],
      workspace_root: ctx.workspace_root,
      hooks_timeout_ms: 1_000,
      codex_command: ctx.opencode,
      codex_router_enabled: false,
      codex_router_default_provider: "default",
      codex_model: "gpt-5",
      codex_model_provider: "openai",
      codex_profiles: %{},
      turn_timeout_ms: 5_000,
      read_timeout_ms: 100,
      stall_timeout_ms: 5_000,
      max_turns: 2,
      recording_enabled: false,
      recording_url: nil,
      recording_ready_timeout_ms: 1_000,
      recording_wait_ms: 0,
      recording_width: 1280,
      recording_height: 720,
      recording_trace: false,
      recording_publish_to_tracker: false,
      review_pr_enabled: false
    }
  end

  defp issue do
    %Symphony.Issue{
      id: "issue-1",
      identifier: "TEST-1",
      title: "Test issue",
      url: "https://linear.example/TEST-1",
      description: "Implement the change",
      state: "In Progress",
      comments: [],
      comments_text: "",
      feedback_assets: [],
      feedback_assets_text: ""
    }
  end

  defp write_mock_file!(path, state_name) do
    File.write!(
      path,
      Jason.encode!([
        %{
          id: "issue-1",
          identifier: "TEST-1",
          title: "Test issue",
          url: "https://linear.example/TEST-1",
          state: state_name,
          priority: 0,
          comments: []
        }
      ])
    )
  end
end
