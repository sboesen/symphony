defmodule Symphony.OrchestratorDecisionTest do
  use ExUnit.Case, async: true

  alias Symphony.OrchestratorDecision

  test "follow_up_for_success handles review-required outcomes" do
    assert OrchestratorDecision.follow_up_for_success(true, :ok) ==
             {:log_only, "tracker_marked_in_review"}

    assert OrchestratorDecision.follow_up_for_success(true, {:error, {:rate_limited, 123}}) ==
             {:pause_and_retry, 123, 1, "tracker_rate_limited"}

    assert OrchestratorDecision.follow_up_for_success(true, {:error, :boom}) ==
             {:log_and_retry, "tracker_mark_in_review_failed", ":boom", 1, "normal_completion"}
  end

  test "follow_up_for_success handles done transitions" do
    assert OrchestratorDecision.follow_up_for_success(false, :ok) ==
             {:log_only, "tracker_marked_done"}

    assert OrchestratorDecision.follow_up_for_success(false, {:error, {:rate_limited, 456}}) ==
             {:pause_and_retry, 456, 1, "tracker_rate_limited"}

    assert OrchestratorDecision.follow_up_for_success(false, {:error, :boom}) ==
             {:log_and_retry, "tracker_mark_done_failed", ":boom", 1, "normal_completion"}
  end

  test "follow_up_for_error classifies clarification, non-retryable, rate-limited, and retryable failures" do
    assert OrchestratorDecision.follow_up_for_error({:clarification_requested, %{}}, 2) ==
             {:log_only, "clarification_requested", "{:clarification_requested, %{}}", 2}

    assert OrchestratorDecision.follow_up_for_error(:recording_setup_command_missing, 3) ==
             {:log_only, "run_failed_non_retryable", ":recording_setup_command_missing", 3}

    assert OrchestratorDecision.follow_up_for_error({:rate_limited, 789}, 4) ==
             {:pause_and_retry, 789, 5, "tracker_rate_limited"}

    assert OrchestratorDecision.follow_up_for_error(:boom, 1) ==
             {:retry, 2, ":boom"}
  end
end
