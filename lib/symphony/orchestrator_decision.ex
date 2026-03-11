defmodule Symphony.OrchestratorDecision do
  @moduledoc false

  def follow_up_for_success(review_required, tracker_result) do
    if review_required do
      case tracker_result do
        :ok ->
          {:log_only, "tracker_marked_in_review"}

        {:error, {:rate_limited, reset_ms}} ->
          {:pause_and_retry, reset_ms, 1, "tracker_rate_limited"}

        {:error, reason} ->
          {:log_and_retry, "tracker_mark_in_review_failed", inspect(reason), 1, "normal_completion"}
      end
    else
      case tracker_result do
        :ok ->
          {:log_only, "tracker_marked_done"}

        {:error, {:rate_limited, reset_ms}} ->
          {:pause_and_retry, reset_ms, 1, "tracker_rate_limited"}

        {:error, reason} ->
          {:log_and_retry, "tracker_mark_done_failed", inspect(reason), 1, "normal_completion"}
      end
    end
  end

  def follow_up_for_error(reason, attempt) do
    cond do
      clarification_requested?(reason) ->
        {:log_only, "clarification_requested", inspect(reason), attempt}

      non_retryable_failure?(reason) ->
        {:log_only, "run_failed_non_retryable", inspect(reason), attempt}

      reset_ms = rate_limit_reset_ms(reason) ->
        {:pause_and_retry, reset_ms, attempt + 1, "tracker_rate_limited"}

      true ->
        {:retry, attempt + 1, inspect(reason)}
    end
  end

  defp rate_limit_reset_ms({:rate_limited, reset_ms}) when is_integer(reset_ms), do: reset_ms
  defp rate_limit_reset_ms({:error, {:rate_limited, reset_ms}}) when is_integer(reset_ms), do: reset_ms
  defp rate_limit_reset_ms(_), do: nil

  defp clarification_requested?({:clarification_requested, _}), do: true
  defp clarification_requested?(_), do: false

  defp non_retryable_failure?({:demo_plan_invalid, _}), do: true
  defp non_retryable_failure?({:recording_capture_failed, _}), do: true
  defp non_retryable_failure?({:recording_setup_failed, _}), do: true
  defp non_retryable_failure?(:recording_setup_command_missing), do: true
  defp non_retryable_failure?(_), do: false
end
