defmodule Symphony.CodexExecRunnerTest do
  use ExUnit.Case, async: true

  alias Symphony.CodexExecRunner

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-codex-exec-runner-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, ".git/symphony"))

    script_path = Path.join(workspace, "fake-codex")
    args_path = Path.join(workspace, "args.txt")

    File.write!(
      script_path,
      """
      #!/bin/bash
      printf '%s\n' "$@" > "#{args_path}"
      printf '%s\n' '{"type":"thread.started","thread_id":"thread_test"}'
      printf '%s\n' '{"type":"turn.started"}'
      sleep 10
      """
    )

    File.chmod!(script_path, 0o755)

    on_exit(fn ->
      File.rm_rf!(workspace)
    end)

    %{workspace: workspace, script_path: script_path, args_path: args_path}
  end

  test "finishes when the workspace contract is satisfied even without turn.completed", %{
    workspace: workspace,
    script_path: script_path
  } do
    File.write!(
      Path.join(workspace, ".git/symphony/plan.json"),
      Jason.encode!(%{
        "summary" => "Already done",
        "steps" => [
          %{"id" => "1", "content" => "Done", "status" => "completed"}
        ]
      })
    )

    File.write!(
      Path.join(workspace, ".git/symphony/result.json"),
      Jason.encode!(%{
        "status" => "completed",
        "summary" => "Done",
        "tests" => [],
        "artifacts" => [],
        "notes" => nil
      })
    )

    File.write!(
      Path.join(workspace, ".git/symphony/demo-plan.json"),
      Jason.encode!(%{
        "non_demoable" => false,
        "url" => "http://127.0.0.1:3000/posts",
        "steps" => [%{"action" => "wait", "ms" => 1000}],
        "assertions" => [%{"type" => "url_includes", "value" => "/posts"}]
      })
    )

    config = %{
      turn_timeout_ms: 30_000,
      read_timeout_ms: 100,
      stall_timeout_ms: 30_000,
      codex_command: script_path,
      openai_api_key: nil
    }

    started_at = System.monotonic_time(:millisecond)

    assert {:ok, %{session_id: "thread_test"}} =
             CodexExecRunner.run_turn(
               workspace,
               config,
               nil,
               1,
               "test prompt",
               %{model: "gpt-5-codex"},
               fn _ -> :ok end
             )

    finished_at = System.monotonic_time(:millisecond)
    assert finished_at - started_at < 8_000
  end

  test "finishes a planning turn when plan.json is written without turn.completed", %{
    workspace: workspace,
    script_path: script_path
  } do
    File.write!(
      Path.join(workspace, ".git/symphony/plan.json"),
      Jason.encode!(%{
        "summary" => "Plan it",
        "steps" => [
          %{"id" => "1", "content" => "Inspect the target", "status" => "pending"}
        ]
      })
    )

    config = %{
      turn_timeout_ms: 30_000,
      read_timeout_ms: 100,
      stall_timeout_ms: 30_000,
      codex_command: script_path,
      openai_api_key: nil
    }

    started_at = System.monotonic_time(:millisecond)

    assert {:ok, %{session_id: "thread_test"}} =
             CodexExecRunner.run_turn(
               workspace,
               config,
               nil,
               1,
               "Create the execution plan for this issue before implementation.",
               %{model: "gpt-5-codex"},
               fn _ -> :ok end
             )

    finished_at = System.monotonic_time(:millisecond)
    assert finished_at - started_at < 8_000
  end

  test "passes configured approval and sandbox settings to codex exec", %{
    workspace: workspace,
    script_path: script_path,
    args_path: args_path
  } do
    File.write!(
      Path.join(workspace, ".git/symphony/plan.json"),
      Jason.encode!(%{
        "summary" => "Plan it",
        "steps" => [
          %{"id" => "1", "content" => "Inspect the target", "status" => "pending"}
        ]
      })
    )

    config = %{
      turn_timeout_ms: 30_000,
      read_timeout_ms: 100,
      stall_timeout_ms: 30_000,
      codex_command: script_path,
      openai_api_key: nil,
      approval_policy: "never",
      thread_sandbox: "workspace-write",
      turn_sandbox_policy: "read-only"
    }

    assert {:ok, %{session_id: "thread_test"}} =
             CodexExecRunner.run_turn(
               workspace,
               config,
               nil,
               1,
               "Create the execution plan for this issue before implementation.",
               %{model: "gpt-5-codex"},
               fn _ -> :ok end
             )

    assert {:ok, args} = File.read(args_path)
    assert args =~ "--ask-for-approval"
    assert args =~ "never"
    assert args =~ "--sandbox"
    assert args =~ "read-only"
    refute args =~ "--dangerously-bypass-approvals-and-sandbox"
  end
end
