defmodule Symphony.OpenCodeRunnerTest do
  use ExUnit.Case, async: true

  alias Symphony.OpenCodeRunner

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-open-code-runner-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, ".git/symphony"))

    script_path = Path.join(workspace, "fake-opencode")

    File.write!(
      script_path,
      """
      #!/bin/bash
      printf '%s\n' '{"type":"session.created","sessionID":"session_test"}'
      printf '%s\n' '{"type":"task.started"}'
      sleep 10
      """
    )

    File.chmod!(script_path, 0o755)

    on_exit(fn ->
      File.rm_rf!(workspace)
    end)

    %{workspace: workspace, script_path: script_path}
  end

  test "finishes an execution turn when result.json is blocked even if plan steps remain", %{
    workspace: workspace,
    script_path: script_path
  } do
    File.write!(
      Path.join(workspace, ".git/symphony/plan.json"),
      Jason.encode!(%{
        "summary" => "Blocked",
        "steps" => [
          %{"id" => "1", "content" => "Need credentials", "status" => "blocked"}
        ]
      })
    )

    File.write!(
      Path.join(workspace, ".git/symphony/result.json"),
      Jason.encode!(%{
        "status" => "blocked",
        "summary" => "Waiting on credentials",
        "tests" => [],
        "artifacts" => [],
        "notes" => nil
      })
    )

    config = %Symphony.Config{
      turn_timeout_ms: 30_000,
      read_timeout_ms: 100,
      stall_timeout_ms: 30_000,
      codex_command: script_path,
      codex_model: "gpt-5",
      codex_router_default_provider: "codex",
      codex_profiles: %{},
      codex_model_provider: "openai",
      openai_api_key: nil,
      zai_api_key: nil,
      openai_base_url: nil
    }

    started_at = System.monotonic_time(:millisecond)

    assert {:ok, %{session_id: "session_test"}} =
             OpenCodeRunner.run_turn(
               workspace,
               config,
               nil,
               1,
               "Implement the change.",
               %{model: "gpt-5"},
               fn _ -> :ok end
             )

    finished_at = System.monotonic_time(:millisecond)
    assert finished_at - started_at < 8_000
  end
end
