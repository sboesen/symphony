defmodule Symphony.GitHubWebhook do
  @moduledoc "Handles GitHub webhook events for PR review lifecycle transitions."

  import Plug.Conn, only: [get_req_header: 2]

  alias Symphony.{Orchestrator, Tracker}

  def handle(conn, payload, session_id \\ nil) do
    if is_map(payload) do
      event = List.first(get_req_header(conn, "x-github-event")) || ""

      with {:ok, config} <- current_config(),
           :ok <- verify_signature(conn, config.github_webhook_secret),
           :ok <- verify_session(session_id),
           {:ok, result} <- dispatch_event(event, payload, config) do
        {:ok, result}
      end
    else
      {:error, :invalid_webhook_payload}
    end
  end

  defp dispatch_event("pull_request", payload, config) do
    action = payload["action"]
    pr = payload["pull_request"] || %{}
    issue_identifier = extract_issue_identifier(pr)

    case issue_identifier do
      nil ->
        {:ok, %{handled: false, reason: "issue_identifier_not_found"}}

      identifier ->
        merged? = pr["merged"] == true

        case action do
          "closed" when merged? ->
            with {:ok, issue} <- Tracker.fetch_issue_by_identifier(config, identifier),
                 true <- not is_nil(issue),
                 :ok <- Tracker.mark_done(config, issue.id) do
              Orchestrator.external_event("github_pr_merged", identifier, %{
                action: action,
                pr_url: pr["html_url"],
                pr_number: pr["number"] || payload["number"]
              })

              {:ok, %{handled: true, issue_identifier: identifier, transition: "done"}}
            else
              false -> {:ok, %{handled: false, issue_identifier: identifier, reason: "issue_not_found"}}
              error -> error
            end

          action when action in ["opened", "reopened", "synchronize"] ->
            Orchestrator.external_event("github_pr_updated", identifier, %{
              action: action,
              pr_url: pr["html_url"],
              pr_number: pr["number"] || payload["number"]
            })

            {:ok, %{handled: true, issue_identifier: identifier, transition: "in_review"}}

          _ ->
            {:ok, %{handled: false, issue_identifier: identifier, action: action}}
        end
    end
  end

  defp dispatch_event("pull_request_review", payload, config) do
    review = payload["review"] || %{}
    pr = payload["pull_request"] || %{}
    identifier = extract_issue_identifier(pr)

    case {identifier, String.downcase(to_string(review["state"] || ""))} do
      {nil, _} ->
        {:ok, %{handled: false, reason: "issue_identifier_not_found"}}

      {issue_identifier, "changes_requested"} ->
        with {:ok, issue} <- Tracker.fetch_issue_by_identifier(config, issue_identifier),
             true <- not is_nil(issue),
             :ok <- Tracker.mark_started(config, issue.id) do
          Orchestrator.external_event("github_review_changes_requested", issue_identifier, %{
            pr_url: pr["html_url"],
            review_state: "changes_requested"
          })

          {:ok, %{handled: true, issue_identifier: issue_identifier, transition: "in_progress"}}
        else
          false -> {:ok, %{handled: false, issue_identifier: issue_identifier, reason: "issue_not_found"}}
          error -> error
        end

      {issue_identifier, state} when state in ["approved", "commented"] ->
        Orchestrator.external_event("github_review_activity", issue_identifier, %{
          pr_url: pr["html_url"],
          review_state: state
        })

        {:ok, %{handled: true, issue_identifier: issue_identifier, transition: "in_review"}}

      {issue_identifier, state} ->
        {:ok, %{handled: false, issue_identifier: issue_identifier, review_state: state}}
    end
  end

  defp dispatch_event(_event, _payload, _config), do: {:ok, %{handled: false, reason: "unsupported_event"}}

  defp current_config do
    case Orchestrator.current_config() do
      %Symphony.Config{} = config -> {:ok, config}
      _ -> {:error, :config_unavailable}
    end
  end

  defp verify_session(nil), do: :ok

  defp verify_session(session_id) when is_binary(session_id) do
    current = Symphony.GitHubWebhookManager.current()

    cond do
      is_nil(current) -> {:error, :webhook_manager_unavailable}
      current.session_id == session_id -> :ok
      true -> {:error, :invalid_webhook_session}
    end
  end

  defp verify_signature(_conn, nil), do: {:error, :github_webhook_secret_missing}
  defp verify_signature(_conn, ""), do: {:error, :github_webhook_secret_missing}

  defp verify_signature(conn, secret) do
    expected = signature(secret, conn.assigns[:raw_body] || "")
    given = List.first(get_req_header(conn, "x-hub-signature-256")) || ""

    if byte_size(given) == byte_size(expected) and Plug.Crypto.secure_compare(given, expected) do
      :ok
    else
      {:error, :invalid_github_signature}
    end
  end

  defp signature(secret, raw_body) do
    digest = :crypto.mac(:hmac, :sha256, secret, raw_body) |> Base.encode16(case: :lower)
    "sha256=" <> digest
  end

  defp extract_issue_identifier(pr) when is_map(pr) do
    title = to_string(pr["title"] || "")
    body = to_string(pr["body"] || "")
    head_ref = get_in(pr, ["head", "ref"]) || pr["headRefName"] || ""

    cond do
      match = Regex.run(~r/\b([A-Z][A-Z0-9]+-\d+)\b/, title, capture: :all_but_first) ->
        List.first(match)

      match = Regex.run(~r/\/issue\/([A-Z][A-Z0-9]+-\d+)\b/, body, capture: :all_but_first) ->
        List.first(match)

      match = Regex.run(~r/\b([a-z][a-z0-9]+-\d+)\b/i, to_string(head_ref), capture: :all_but_first) ->
        match |> List.first() |> String.upcase()

      true ->
        nil
    end
  end

  defp extract_issue_identifier(_), do: nil
end
