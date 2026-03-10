defmodule Symphony.LinearWebhook do
  @moduledoc "Handles Linear webhook events for project-scoped refresh and review lifecycle reconciliation."

  alias Symphony.{Issue, Orchestrator}

  def handle(conn, payload, project_slug \\ nil) do
    if is_map(payload) do
      headers = Map.new(conn.req_headers, fn {key, value} -> {String.downcase(key), value} end)
      handle_payload(payload, headers, conn.assigns[:raw_body] || "", project_slug)
    else
      {:error, :invalid_webhook_payload}
    end
  end

  def handle_payload(payload, headers, raw_body, project_slug \\ nil) when is_map(payload) do
    with {:ok, config} <- current_config(),
         :ok <- verify_signature(headers, raw_body, config.linear_webhook_secret),
         :ok <- verify_project(project_slug, config),
         {:ok, result} <- dispatch_event(payload, project_slug) do
      {:ok, result}
    end
  end

  defp dispatch_event(payload, project_slug) do
    event_type =
      Map.get(payload, "action") ||
        Map.get(payload, "type") ||
        get_in(payload, ["webhook", "event"]) ||
        "linear_webhook"

    normalized_event_type = normalize_event_type(event_type)
    issue_identifier = extract_issue_identifier(payload)

    Orchestrator.external_event("linear_webhook_received", issue_identifier, %{
      event_type: normalized_event_type,
      project_slug: project_slug,
      issue_identifier: issue_identifier
    })

    force_done? = done_transition?(payload)
    should_refresh? = should_refresh_event?(payload, normalized_event_type)

    case maybe_refresh(should_refresh?, issue_identifier, force_done?) do
      {:ok, refreshed, merge_result} ->
        {:ok,
         %{
           handled: true,
           event_type: normalized_event_type,
           issue_identifier: issue_identifier,
            refreshed: refreshed,
           force_done: force_done?,
           merge_result: normalize_merge_result(merge_result)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_refresh(false, issue_identifier, force_done?) do
    merge_result =
      if is_binary(issue_identifier) and issue_identifier != "" and force_done? do
        queue_merge_review_handoff(issue_identifier, force_done: true)
      else
        :skipped
      end

    {:ok, false, merge_result}
  end

  defp maybe_refresh(true, issue_identifier, force_done?) do
    case Orchestrator.refresh() do
      {:ok, _payload} ->
        merge_result =
          if is_binary(issue_identifier) and issue_identifier != "" do
            queue_merge_review_handoff(issue_identifier, force_done: force_done?)
          else
            :skipped
          end

        {:ok, true, merge_result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_merge_result({:ok, result}), do: %{ok: true, result: inspect(result)}
  defp normalize_merge_result({:error, reason}), do: %{ok: false, error: inspect(reason)}
  defp normalize_merge_result(:queued), do: %{ok: true, result: "queued"}
  defp normalize_merge_result(:skipped), do: %{ok: true, result: "skipped"}
  defp normalize_merge_result(other), do: %{ok: false, error: inspect(other)}

  defp queue_merge_review_handoff(issue_identifier, opts) do
    Task.start(fn ->
      _ = Orchestrator.merge_review_handoff(issue_identifier, opts)
    end)

    :queued
  end

  defp current_config do
    try do
      case Process.whereis(Symphony.Orchestrator) do
        nil ->
          {:error, :config_unavailable}

        _pid ->
          case Orchestrator.current_config() do
            %Symphony.Config{} = config -> {:ok, config}
            _ -> {:error, :config_unavailable}
          end
      end
    rescue
      _ -> {:error, :config_unavailable}
    catch
      :exit, _ -> {:error, :config_unavailable}
    end
  end

  defp verify_project(nil, _config), do: :ok

  defp verify_project(project_slug, config) when is_binary(project_slug) do
    normalized = project_slug |> String.trim() |> String.downcase()
    expected = to_string(config.tracker_project_slug || "") |> String.trim() |> String.downcase()

    if normalized == "" or normalized == expected do
      :ok
    else
      {:error, :invalid_linear_webhook_project}
    end
  end

  defp verify_signature(_headers, _raw_body, nil), do: {:error, :linear_webhook_secret_missing}
  defp verify_signature(_headers, _raw_body, ""), do: {:error, :linear_webhook_secret_missing}

  defp verify_signature(headers, raw_body, secret) when is_map(headers) do
    expected = signature(secret, raw_body)
    given = Map.get(headers, "linear-signature", "")

    if byte_size(given) == byte_size(expected) and Plug.Crypto.secure_compare(given, expected) do
      :ok
    else
      {:error, :invalid_linear_signature}
    end
  end

  defp signature(secret, raw_body) do
    :crypto.mac(:hmac, :sha256, secret, raw_body) |> Base.encode16(case: :lower)
  end

  defp extract_issue_identifier(%{"data" => %{"identifier" => identifier}}) when is_binary(identifier),
    do: identifier

  defp extract_issue_identifier(%{"data" => %{"issue" => %{"identifier" => identifier}}})
       when is_binary(identifier),
       do: identifier

  defp extract_issue_identifier(%{"issue" => %{"identifier" => identifier}})
       when is_binary(identifier),
       do: identifier

  defp extract_issue_identifier(_), do: nil

  defp done_transition?(payload) when is_map(payload) do
    payload
    |> candidate_state_values()
    |> Enum.any?(&done_state_value?/1)
  end

  defp should_refresh_event?(payload, event_type) do
    cond do
      done_transition?(payload) ->
        true

      symphony_comment_event?(payload, event_type) ->
        false

      issue_state_event?(payload) ->
        true

      comment_event?(event_type) ->
        true

      true ->
        false
    end
  end

  defp symphony_comment_event?(payload, event_type) do
    comment_event?(event_type) and
      payload
      |> extract_comment_body()
      |> Issue.symphony_managed_comment?()
  end

  defp comment_event?(event_type) do
    normalized = normalize_event_type(event_type)
    String.contains?(normalized, "comment")
  end

  defp normalize_event_type(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_event_type(value), do: value |> to_string() |> normalize_event_type()

  defp extract_comment_body(payload) when is_map(payload) do
    [
      get_in(payload, ["data", "body"]),
      get_in(payload, ["data", "comment", "body"]),
      get_in(payload, ["data", "issueComment", "body"]),
      get_in(payload, ["comment", "body"]),
      get_in(payload, ["issueComment", "body"])
    ]
    |> Enum.find("", &is_binary/1)
  end

  defp issue_payload?(payload) when is_map(payload) do
    is_binary(extract_issue_identifier(payload)) and extract_issue_identifier(payload) != ""
  end

  defp issue_state_event?(payload) when is_map(payload) do
    issue_payload?(payload) and candidate_state_values(payload) != []
  end

  defp candidate_state_values(payload) do
    [
      get_in(payload, ["data", "state", "type"]),
      get_in(payload, ["data", "state", "name"]),
      get_in(payload, ["data", "toState", "type"]),
      get_in(payload, ["data", "toState", "name"]),
      get_in(payload, ["data", "issue", "state", "type"]),
      get_in(payload, ["data", "issue", "state", "name"]),
      get_in(payload, ["issue", "state", "type"]),
      get_in(payload, ["issue", "state", "name"])
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp done_state_value?(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.downcase()

    normalized in ["done", "completed", "complete"]
  end
end
