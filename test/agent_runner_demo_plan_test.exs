defmodule Symphony.AgentRunnerDemoPlanTest do
  use ExUnit.Case, async: false

  alias Symphony.AgentRunnerDemoPlan

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "symphony-demo-plan-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(workspace) end)

    %{workspace: workspace}
  end

  test "validate_map accepts non-demoable plans" do
    assert :ok = AgentRunnerDemoPlan.validate_map(%{"non_demoable" => true})
  end

  test "validate_map requires setup commands for local urls" do
    assert {:error, :recording_setup_command_missing} =
             AgentRunnerDemoPlan.validate_map(%{"url" => "http://127.0.0.1:3000"})

    assert :ok =
             AgentRunnerDemoPlan.validate_map(%{
               "ready_url" => "http://localhost:3000",
               "setup_command" => "npm run dev"
             })
  end

  test "validate_map accepts non-local urls and rejects malformed plans" do
    assert :ok = AgentRunnerDemoPlan.validate_map(%{"url" => "https://example.com/demo"})
    assert {:error, :demo_plan_invalid} = AgentRunnerDemoPlan.validate_map(:bad)
  end

  test "plan_string normalizes blank strings" do
    assert AgentRunnerDemoPlan.plan_string(%{"url" => "  https://example.com  "}, "url") ==
             "https://example.com"

    assert AgentRunnerDemoPlan.plan_string(%{"url" => "   "}, "url") == nil
    assert AgentRunnerDemoPlan.plan_string(%{}, "missing") == nil
  end

  test "validate_file loads demo plans from disk", %{workspace: workspace} do
    symphony_dir = Path.join(workspace, ".git/symphony")
    File.mkdir_p!(symphony_dir)

    path = Path.join(symphony_dir, "demo-plan.json")
    File.write!(path, Jason.encode!(%{"url" => "https://example.com/demo"}))

    assert :ok = AgentRunnerDemoPlan.validate_file(path)

    File.write!(path, "{")
    assert match?({:error, _}, AgentRunnerDemoPlan.validate_file(path))
  end
end
