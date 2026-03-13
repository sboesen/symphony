defmodule Symphony.OrchestratorRuntimeEvent do
  @moduledoc false

  def format(%{type: type, issue_identifier: issue, details: details}) do
    prefix =
      case issue do
        nil -> "[symphony]"
        value -> "[#{value}]"
      end

    case type do
      "issue_dispatched" ->
        "#{prefix} dispatched (attempt #{details[:attempt] || details["attempt"] || 1})"

      "tracker_marked_started" ->
        "#{prefix} moved to In Progress#{format_elapsed(details)}"

      "tracker_mark_started_started" ->
        "#{prefix} marking In Progress"

      "tracker_mark_started_failed" ->
        "#{prefix} failed to mark In Progress#{format_elapsed(details)}: #{details[:reason] || details["reason"]}"

      "workpad_placeholder_started" ->
        "#{prefix} posting plan placeholder"

      "workpad_placeholder_synced" ->
        "#{prefix} plan placeholder posted#{format_elapsed(details)}"

      "workpad_placeholder_deferred" ->
        "#{prefix} plan placeholder deferred#{format_elapsed(details)}: #{details[:reason] || details["reason"]}"

      "workpad_placeholder_failed" ->
        "#{prefix} plan placeholder failed#{format_elapsed(details)}: #{details[:reason] || details["reason"]}"

      "workspace_setup_started" ->
        "#{prefix} workspace setup started"

      "workspace_setup_finished" ->
        "#{prefix} workspace setup finished#{format_elapsed(details)}"

      "workspace_setup_failed" ->
        "#{prefix} workspace setup failed: #{details[:reason] || details["reason"]}"

      "planning_turn_started" ->
        "#{prefix} planning started"

      "planning_turn_finished" ->
        "#{prefix} planning finished#{format_elapsed(details)}"

      "planning_turn_failed" ->
        "#{prefix} planning failed#{format_elapsed(details)}: #{details[:reason] || details["reason"]}"

      "workpad_synced" ->
        action = details[:action] || details["action"]
        suffix = if action, do: " (#{action})", else: ""
        "#{prefix} plan synced#{suffix}#{format_elapsed(details)}"

      "issue_refresh_started" ->
        "#{prefix} refreshing issue"

      "issue_refresh_finished" ->
        "#{prefix} issue refreshed#{format_elapsed(details)}"

      "issue_refresh_failed" ->
        "#{prefix} issue refresh failed#{format_elapsed(details)}: #{details[:reason] || details["reason"]}"

      "execution_turn_started" ->
        "#{prefix} execution started"

      "execution_turn_finished" ->
        "#{prefix} execution finished#{format_elapsed(details)}"

      "execution_turn_failed" ->
        "#{prefix} execution failed#{format_elapsed(details)}: #{details[:reason] || details["reason"]}"

      "routing_selected" ->
        "#{prefix} routed to #{details[:provider] || details["provider"]}/#{details[:model] || details["model"]}"

      "session_started" ->
        "#{prefix} model session started"

      "demo_capture_started" ->
        "#{prefix} demo capture started"

      "demo_capture_repair_requested" ->
        "#{prefix} demo plan repair requested"

      "demo_capture_succeeded" ->
        "#{prefix} demo capture succeeded#{format_elapsed(details)}"

      "demo_capture_skipped" ->
        "#{prefix} demo capture skipped"

      "demo_capture_failed" ->
        "#{prefix} demo capture failed#{format_elapsed(details)}: #{details[:reason] || details["reason"]}"

      "run_finished" ->
        "#{prefix} run finished (#{details[:outcome] || details["outcome"]})"

      "run_failed" ->
        "#{prefix} run failed: #{details[:reason] || details["reason"]}"

      "tracker_marked_in_review" ->
        "#{prefix} moved to In Review"

      "tracker_marked_done" ->
        "#{prefix} moved to Done"

      "review_pr_merged_from_done" ->
        "#{prefix} merged review PR"

      "clarification_requested" ->
        "#{prefix} clarification requested"

      "retry_scheduled" ->
        "#{prefix} retry scheduled"

      _ ->
        nil
    end
  end

  def format_elapsed(details) do
    value = details[:elapsed_ms] || details["elapsed_ms"]

    if is_integer(value) and value >= 0 do
      " in #{Float.round(value / 1000, 1)}s"
    else
      ""
    end
  end
end
