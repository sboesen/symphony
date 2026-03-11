defmodule Symphony.AgentRunnerDecisionTest do
  use ExUnit.Case, async: true

  alias Symphony.AgentRunnerDecision

  test "completed turns stop only when the plan is ready" do
    assert :stop =
             AgentRunnerDecision.next_turn_action(%{status: "completed"}, %{plan_ready: :ok})

    assert {:error, :plan_missing} =
             AgentRunnerDecision.next_turn_action(%{status: "completed"}, %{
               plan_ready: {:error, :plan_missing}
             })
  end

  test "blocked turns always return blocked completion errors" do
    completion = %{status: "blocked", notes: "Need info"}

    assert {:error, {:blocked, ^completion}} =
             AgentRunnerDecision.next_turn_action(completion, %{})
  end

  test "needs_more_work turns continue only when active and making progress" do
    completion = %{status: "needs_more_work"}

    assert {:error, {:max_turns_exceeded, ^completion}} =
             AgentRunnerDecision.next_turn_action(completion, %{
               turn_index: 2,
               max_turns: 2,
               issue_state: "In Progress",
               active_states: ["todo", "in progress"],
               progress_made?: true
             })

    assert {:error, {:needs_more_work_but_issue_not_active, ^completion}} =
             AgentRunnerDecision.next_turn_action(completion, %{
               turn_index: 1,
               max_turns: 2,
               issue_state: "Done",
               active_states: ["todo", "in progress"],
               progress_made?: true
             })

    assert {:error, {:needs_more_work_without_progress, ^completion}} =
             AgentRunnerDecision.next_turn_action(completion, %{
               turn_index: 1,
               max_turns: 2,
               issue_state: "In Progress",
               active_states: ["todo", "in progress"],
               progress_made?: false
             })

    assert :continue =
             AgentRunnerDecision.next_turn_action(completion, %{
               turn_index: 1,
               max_turns: 2,
               issue_state: "In Progress",
               active_states: ["todo", "in progress"],
               progress_made?: true
             })
  end

  test "timeout salvage prefers explicit completion results and otherwise falls back to workspace evidence" do
    completion = %{status: "completed", summary: "Done"}

    assert {:ok, %{status: "completed", completion: ^completion}} =
             AgentRunnerDecision.salvage_timeout_result(
               :turn_timeout,
               {:ok, completion},
               false,
               false
             )

    assert {:ok, %{status: "completed", completion: nil, salvaged: true}} =
             AgentRunnerDecision.salvage_timeout_result(
               :stall_timeout,
               {:error, :missing},
               true,
               false
             )

    assert {:ok, %{status: "completed", completion: nil, salvaged: true}} =
             AgentRunnerDecision.salvage_timeout_result(
               :stall_timeout,
               {:error, :missing},
               false,
               true
             )

    assert :no_salvage =
             AgentRunnerDecision.salvage_timeout_result(
               :stall_timeout,
               {:error, :missing},
               false,
               false
             )

    assert :no_salvage =
             AgentRunnerDecision.salvage_timeout_result(
               :other_error,
               {:ok, completion},
               true,
               true
             )
  end
end
