defmodule Symphony.Tracker do
  @moduledoc "Tracker strategy dispatch wrapper."

  def fetch_candidates(config), do: tracker_call(:fetch_candidates, config)
  def fetch_states_by_ids(config, ids), do: tracker_call(:fetch_states_by_ids, config, ids)
  def fetch_terminal_issues(config, states), do: tracker_call(:fetch_terminal_issues, config, states)
  def mark_started(config, issue_id), do: tracker_call(:mark_started, config, issue_id)
  def mark_completed(config, issue_id), do: tracker_call(:mark_completed, config, issue_id)
  def publish_artifacts(config, issue, artifacts), do: tracker_call(:publish_artifacts, config, {issue, artifacts})
  def publish_review_handoff(config, issue, review_artifact),
    do: tracker_call(:publish_review_handoff, config, {issue, review_artifact})

  defp tracker_call(fun, config, args \\ nil) do
    case config.tracker_kind do
      "linear" ->
        dispatch_linear_call(fun, config, args)

      "mock" ->
        dispatch_mock_call(fun, config, args)

      _ ->
        {:error, :unsupported_tracker}
    end
  end

  defp dispatch_linear_call(:fetch_candidates, config, _args) do
    Symphony.Tracker.LinearClient.fetch_candidates(config)
  end

  defp dispatch_linear_call(:fetch_states_by_ids, config, args) do
    Symphony.Tracker.LinearClient.fetch_states_by_ids(config, maybe_list(args))
  end

  defp dispatch_linear_call(:fetch_terminal_issues, config, args) do
    Symphony.Tracker.LinearClient.fetch_terminal_issues(config, maybe_list(args))
  end

  defp dispatch_linear_call(:mark_started, config, issue_id) do
    Symphony.Tracker.LinearClient.mark_started(config, issue_id)
  end

  defp dispatch_linear_call(:mark_completed, config, issue_id) do
    Symphony.Tracker.LinearClient.mark_completed(config, issue_id)
  end

  defp dispatch_linear_call(:publish_artifacts, config, {issue, artifacts}) do
    Symphony.Tracker.LinearClient.publish_artifacts(config, issue, maybe_list(artifacts))
  end

  defp dispatch_linear_call(:publish_review_handoff, config, {issue, review_artifact}) do
    Symphony.Tracker.LinearClient.publish_review_handoff(config, issue, review_artifact)
  end

  defp dispatch_linear_call(_, _config, _args), do: {:error, :unsupported_tracker_call}

  defp dispatch_mock_call(:fetch_candidates, config, _args) do
    Symphony.Tracker.MockClient.fetch_candidates(config)
  end

  defp dispatch_mock_call(:fetch_states_by_ids, config, args) do
    Symphony.Tracker.MockClient.fetch_states_by_ids(config, maybe_list(args))
  end

  defp dispatch_mock_call(:fetch_terminal_issues, config, args) do
    Symphony.Tracker.MockClient.fetch_terminal_issues(config, maybe_list(args))
  end

  defp dispatch_mock_call(:mark_started, config, issue_id) do
    Symphony.Tracker.MockClient.mark_started(config, issue_id)
  end

  defp dispatch_mock_call(:mark_completed, config, issue_id) do
    Symphony.Tracker.MockClient.mark_completed(config, issue_id)
  end

  defp dispatch_mock_call(:publish_artifacts, _config, {_issue, artifacts}) do
    {:ok, maybe_list(artifacts)}
  end

  defp dispatch_mock_call(:publish_review_handoff, _config, {_issue, review_artifact}) do
    {:ok, review_artifact}
  end

  defp dispatch_mock_call(_, _config, _args), do: {:error, :unsupported_tracker_call}

  defp maybe_list(nil), do: []
  defp maybe_list(v), do: List.wrap(v)
end
