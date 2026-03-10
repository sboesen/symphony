defmodule Symphony.Tracker do
  @moduledoc "Tracker strategy dispatch wrapper."

  def fetch_candidates(config), do: tracker_call(:fetch_candidates, config)
  def list_projects(config), do: tracker_call(:list_projects, config)
  def fetch_project_by_slug(config, slug), do: tracker_call(:fetch_project_by_slug, config, slug)
  def save_project_repo(config, project, repo_url), do: tracker_call(:save_project_repo, config, {project, repo_url})
  def list_webhooks(config), do: tracker_call(:list_webhooks, config)
  def create_webhook(config, attrs), do: tracker_call(:create_webhook, config, attrs)
  def delete_webhook(config, webhook_id), do: tracker_call(:delete_webhook, config, webhook_id)
  def fetch_states_by_ids(config, ids), do: tracker_call(:fetch_states_by_ids, config, ids)
  def fetch_issue_by_identifier(config, identifier),
    do: tracker_call(:fetch_issue_by_identifier, config, identifier)
  def fetch_terminal_issues(config, states), do: tracker_call(:fetch_terminal_issues, config, states)
  def mark_started(config, issue_id), do: tracker_call(:mark_started, config, issue_id)
  def mark_todo(config, issue_id), do: tracker_call(:mark_todo, config, issue_id)
  def mark_backlog(config, issue_id), do: tracker_call(:mark_backlog, config, issue_id)
  def mark_in_review(config, issue_id), do: tracker_call(:mark_in_review, config, issue_id)
  def mark_done(config, issue_id), do: tracker_call(:mark_done, config, issue_id)
  def mark_completed(config, issue_id), do: mark_in_review(config, issue_id)
  def publish_clarification(config, issue, body, preferred_comment_id \\ nil),
    do: tracker_call(:publish_clarification, config, {issue, body, preferred_comment_id})
  def publish_artifacts(config, issue, artifacts), do: tracker_call(:publish_artifacts, config, {issue, artifacts})
  def publish_review_handoff(config, issue, review_artifact),
    do: tracker_call(:publish_review_handoff, config, {issue, review_artifact})
  def upsert_workpad(config, issue, body, preferred_comment_id \\ nil),
    do: tracker_call(:upsert_workpad, config, {issue, body, preferred_comment_id})

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

  defp dispatch_linear_call(:list_projects, config, _args) do
    Symphony.Tracker.LinearClient.list_projects(config)
  end

  defp dispatch_linear_call(:fetch_project_by_slug, config, slug) do
    Symphony.Tracker.LinearClient.fetch_project_by_slug(config, slug)
  end

  defp dispatch_linear_call(:save_project_repo, config, {project, repo_url}) do
    Symphony.Tracker.LinearClient.save_project_repo(config, project, repo_url)
  end

  defp dispatch_linear_call(:list_webhooks, config, _args) do
    Symphony.Tracker.LinearClient.list_webhooks(config)
  end

  defp dispatch_linear_call(:create_webhook, config, attrs) do
    Symphony.Tracker.LinearClient.create_webhook(config, attrs || %{})
  end

  defp dispatch_linear_call(:delete_webhook, config, webhook_id) do
    Symphony.Tracker.LinearClient.delete_webhook(config, webhook_id)
  end

  defp dispatch_linear_call(:fetch_states_by_ids, config, args) do
    Symphony.Tracker.LinearClient.fetch_states_by_ids(config, maybe_list(args))
  end

  defp dispatch_linear_call(:fetch_issue_by_identifier, config, identifier) do
    Symphony.Tracker.LinearClient.fetch_issue_by_identifier(config, identifier)
  end

  defp dispatch_linear_call(:fetch_terminal_issues, config, args) do
    Symphony.Tracker.LinearClient.fetch_terminal_issues(config, maybe_list(args))
  end

  defp dispatch_linear_call(:mark_started, config, issue_id) do
    Symphony.Tracker.LinearClient.mark_started(config, issue_id)
  end

  defp dispatch_linear_call(:mark_todo, config, issue_id) do
    Symphony.Tracker.LinearClient.mark_todo(config, issue_id)
  end

  defp dispatch_linear_call(:mark_backlog, config, issue_id) do
    Symphony.Tracker.LinearClient.mark_backlog(config, issue_id)
  end

  defp dispatch_linear_call(:mark_in_review, config, issue_id) do
    Symphony.Tracker.LinearClient.mark_in_review(config, issue_id)
  end

  defp dispatch_linear_call(:mark_done, config, issue_id) do
    Symphony.Tracker.LinearClient.mark_done(config, issue_id)
  end

  defp dispatch_linear_call(:publish_artifacts, config, {issue, artifacts}) do
    Symphony.Tracker.LinearClient.publish_artifacts(config, issue, maybe_list(artifacts))
  end

  defp dispatch_linear_call(:publish_clarification, config, {issue, body, preferred_comment_id}) do
    Symphony.Tracker.LinearClient.publish_clarification(config, issue, body, preferred_comment_id)
  end

  defp dispatch_linear_call(:publish_review_handoff, config, {issue, review_artifact}) do
    Symphony.Tracker.LinearClient.publish_review_handoff(config, issue, review_artifact)
  end

  defp dispatch_linear_call(:upsert_workpad, config, {issue, body, preferred_comment_id}) do
    Symphony.Tracker.LinearClient.upsert_workpad(config, issue, body, preferred_comment_id)
  end

  defp dispatch_linear_call(_, _config, _args), do: {:error, :unsupported_tracker_call}

  defp dispatch_mock_call(:fetch_candidates, config, _args) do
    Symphony.Tracker.MockClient.fetch_candidates(config)
  end

  defp dispatch_mock_call(:list_projects, _config, _args) do
    {:ok, [%{id: "mock-project", name: "Mock Project", slug_id: "mock-project", repo_url: nil}]}
  end

  defp dispatch_mock_call(:fetch_project_by_slug, _config, slug) do
    {:ok, %{id: "mock-project", name: "Mock Project", slug_id: slug, repo_url: nil}}
  end

  defp dispatch_mock_call(:save_project_repo, _config, {project, repo_url}) do
    {:ok, Map.put(project, :repo_url, repo_url)}
  end

  defp dispatch_mock_call(:list_webhooks, _config, _args), do: {:ok, []}

  defp dispatch_mock_call(:create_webhook, _config, attrs) do
    {:ok, Map.merge(%{id: "mock-linear-webhook"}, Map.new(attrs || %{}))}
  end

  defp dispatch_mock_call(:delete_webhook, _config, webhook_id) do
    {:ok, %{id: webhook_id}}
  end

  defp dispatch_mock_call(:fetch_states_by_ids, config, args) do
    Symphony.Tracker.MockClient.fetch_states_by_ids(config, maybe_list(args))
  end

  defp dispatch_mock_call(:fetch_issue_by_identifier, config, identifier) do
    Symphony.Tracker.MockClient.fetch_issue_by_identifier(config, identifier)
  end

  defp dispatch_mock_call(:fetch_terminal_issues, config, args) do
    Symphony.Tracker.MockClient.fetch_terminal_issues(config, maybe_list(args))
  end

  defp dispatch_mock_call(:mark_started, config, issue_id) do
    Symphony.Tracker.MockClient.mark_started(config, issue_id)
  end

  defp dispatch_mock_call(:mark_todo, config, issue_id) do
    Symphony.Tracker.MockClient.mark_todo(config, issue_id)
  end

  defp dispatch_mock_call(:mark_backlog, config, issue_id) do
    Symphony.Tracker.MockClient.mark_backlog(config, issue_id)
  end

  defp dispatch_mock_call(:mark_in_review, config, issue_id) do
    Symphony.Tracker.MockClient.mark_in_review(config, issue_id)
  end

  defp dispatch_mock_call(:mark_done, config, issue_id) do
    Symphony.Tracker.MockClient.mark_done(config, issue_id)
  end

  defp dispatch_mock_call(:publish_artifacts, _config, {_issue, artifacts}) do
    {:ok, maybe_list(artifacts)}
  end

  defp dispatch_mock_call(:publish_review_handoff, _config, {_issue, review_artifact}) do
    {:ok, review_artifact}
  end

  defp dispatch_mock_call(:publish_clarification, _config, {_issue, body, _preferred_comment_id}) do
    {:ok, %{comment_id: "mock-clarification", body: body}}
  end

  defp dispatch_mock_call(:upsert_workpad, _config, {_issue, body, _preferred_comment_id}) do
    {:ok, %{body: body, comment_id: "mock-workpad"}}
  end

  defp dispatch_mock_call(_, _config, _args), do: {:error, :unsupported_tracker_call}

  defp maybe_list(nil), do: []
  defp maybe_list(v), do: List.wrap(v)
end
