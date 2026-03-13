defmodule Symphony.OrchestratorRuntimeEventTest do
  use ExUnit.Case, async: true

  alias Symphony.OrchestratorRuntimeEvent

  test "format renders representative runtime events" do
    assert OrchestratorRuntimeEvent.format(%{
             type: "issue_dispatched",
             issue_identifier: "TEST-1",
             details: %{attempt: 2}
           }) == "[TEST-1] dispatched (attempt 2)"

    assert OrchestratorRuntimeEvent.format(%{
             type: "workpad_synced",
             issue_identifier: "TEST-1",
             details: %{action: "update", elapsed_ms: 1200}
           }) == "[TEST-1] plan synced (update) in 1.2s"

    assert OrchestratorRuntimeEvent.format(%{
             type: "routing_selected",
             issue_identifier: "TEST-1",
             details: %{provider: "openai", model: "gpt-5"}
           }) == "[TEST-1] routed to openai/gpt-5"

    assert OrchestratorRuntimeEvent.format(%{
             type: "run_failed",
             issue_identifier: nil,
             details: %{reason: ":boom"}
           }) == "[symphony] run failed: :boom"
  end

  test "format handles elapsed and unknown events" do
    assert OrchestratorRuntimeEvent.format(%{
             type: "workspace_setup_finished",
             issue_identifier: "TEST-1",
             details: %{"elapsed_ms" => 500}
           }) == "[TEST-1] workspace setup finished in 0.5s"

    assert OrchestratorRuntimeEvent.format(%{
             type: "tracker_mark_started_failed",
             issue_identifier: "TEST-1",
             details: %{reason: "oops", elapsed_ms: -1}
           }) == "[TEST-1] failed to mark In Progress: oops"

    assert OrchestratorRuntimeEvent.format(%{
             type: "unknown",
             issue_identifier: "TEST-1",
             details: %{}
           }) == nil
  end

  test "format_elapsed only prints non-negative integer durations" do
    assert OrchestratorRuntimeEvent.format_elapsed(%{elapsed_ms: 2500}) == " in 2.5s"
    assert OrchestratorRuntimeEvent.format_elapsed(%{"elapsed_ms" => 0}) == " in 0.0s"
    assert OrchestratorRuntimeEvent.format_elapsed(%{elapsed_ms: -1}) == ""
    assert OrchestratorRuntimeEvent.format_elapsed(%{}) == ""
  end
end
