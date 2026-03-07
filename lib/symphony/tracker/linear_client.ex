defmodule Symphony.Tracker.LinearClient do
  @moduledoc "Linear GraphQL API client used by the orchestrator."

  alias Symphony.Issue
  require Logger

  @page_size 100

  def fetch_candidates(config) do
    fetch_by_states(config, config.tracker_active_states)
  end

  def mark_started(config, issue_id) do
    transition_issue_state(config, issue_id, "started")
  end

  def mark_in_review(config, issue_id) do
    transition_issue_state(config, issue_id, "in_review")
  end

  def mark_done(config, issue_id) do
    transition_issue_state(config, issue_id, "completed")
  end

  def publish_artifacts(config, %Issue{} = issue, artifacts) when is_list(artifacts) do
    if not config.recording_publish_to_tracker do
      {:ok, artifacts}
    else
      artifacts
      |> Enum.reduce_while({:ok, []}, fn artifact, {:ok, acc} ->
        case publish_artifact(config, issue, artifact) do
          {:ok, published_artifact} ->
            {:cont, {:ok, [published_artifact | acc]}}

          {:error, reason, artifact_with_error} ->
            {:halt, {:error, reason, Enum.reverse([artifact_with_error | acc])}}
        end
      end)
      |> case do
        {:ok, published_artifacts} -> {:ok, Enum.reverse(published_artifacts)}
        {:error, reason, published_artifacts} -> {:error, reason, published_artifacts}
      end
    end
  end

  def publish_review_handoff(_config, %Issue{} = _issue, nil), do: {:ok, nil}

  def publish_review_handoff(config, %Issue{} = issue, review_artifact) when is_map(review_artifact) do
    with pr_url when is_binary(pr_url) <- review_artifact[:pr_url] || review_artifact["pr_url"],
         pr_title <- review_artifact[:pr_title] || review_artifact["pr_title"] || "Review PR",
         {:ok, attachment_id} <- create_attachment(config, issue, pr_url, pr_title, "Symphony review PR"),
         {:ok, comment_id} <- maybe_create_review_comment(config, issue, review_artifact) do
      {:ok,
       review_artifact
       |> Map.put(:linear_attachment_id, attachment_id)
       |> Map.put(:linear_comment_id, comment_id)}
    else
      nil -> {:ok, review_artifact}
      {:error, reason} -> {:error, reason}
    end
  end

  def fetch_issue_by_identifier(config, identifier) when is_binary(identifier) do
    query = """
    query($identifier: String!) {
      issues(filter: { identifier: { eq: $identifier } }, first: 1) {
        nodes {
          id
          identifier
          title
          description
          comments(first: 8) {
            nodes {
              id
              body
              createdAt
              updatedAt
              user { name }
            }
          }
          priority
          state { name }
          branchName
          url
          labels { nodes { name } }
          createdAt
          updatedAt
        }
      }
    }
    """

    with {:ok, payload} <-
           execute_query(config, query, %{identifier: String.trim(identifier)}, &get_in(&1, ["data", "issues", "nodes"])),
         [issue | _] <- payload do
      {:ok, Issue.from_payload(issue)}
    else
      [] -> {:ok, nil}
      {:error, _} = error -> error
      _ -> {:error, :malformed_graphql}
    end
  end

  def fetch_states_by_ids(_config, []), do: {:ok, []}

  def fetch_states_by_ids(config, issue_ids) when is_list(issue_ids) do
    query = """
    query($id: String!) {
      issue(id: $id) {
        id
        identifier
        title
        description
        comments(first: 8) {
          nodes {
            id
            body
            createdAt
            updatedAt
            user { name }
          }
        }
        priority
        state { name }
        branchName
        url
        labels { nodes { name } }
        createdAt
        updatedAt
      }
    }
    """

    issue_ids
    |> Enum.reduce_while({:ok, []}, fn issue_id, {:ok, acc} ->
      case execute_query(config, query, %{id: issue_id}, &get_in(&1, ["data", "issue"])) do
        {:ok, issue} when is_map(issue) ->
          {:cont, {:ok, [Issue.from_payload(issue) | acc]}}

        {:ok, nil} ->
          {:cont, {:ok, acc}}

        {:ok, _other} ->
          {:halt, {:error, :malformed_graphql}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      error -> error
    end
  end

  def fetch_terminal_issues(config, terminal_states) do
    fetch_by_states(config, terminal_states)
  end

  defp fetch_by_states(config, states) do
    wanted_states = normalize_state_set(states)

    if MapSet.size(wanted_states) == 0 do
      {:ok, []}
    else
      fetch_loop(config, nil, [], wanted_states)
    end
  end

  defp publish_artifact(config, %Issue{} = issue, artifact) when is_map(artifact) do
    case artifact_file_path(artifact) do
      nil ->
        {:ok, Map.put(artifact, :published, false)}

      path ->
        with {:ok, filename} <- artifact_filename(path),
             {:ok, stat} <- File.stat(path),
             {:ok, content_type} <- content_type_for(path),
             {:ok, upload} <- create_file_upload(config, filename, stat.size, content_type),
             :ok <- upload_file(upload, path, content_type),
             {:ok, attachment_id} <-
               create_attachment(config, issue, upload.asset_url, filename, "Symphony recording"),
             {:ok, comment_id} <- maybe_create_comment(config, issue, upload.asset_url, filename) do
          {:ok,
           artifact
           |> Map.put(:published, true)
           |> Map.put(:published_to, "linear")
           |> Map.put(:linear_asset_url, upload.asset_url)
           |> Map.put(:linear_attachment_id, attachment_id)
           |> Map.put(:linear_comment_id, comment_id)}
        else
          {:error, reason} ->
            Logger.warning(
              "failed to publish artifact for issue #{issue.identifier}: #{inspect(reason)}"
            )

            {:error, reason,
             artifact
             |> Map.put(:published, false)
             |> Map.put(:publish_error, inspect(reason))}
        end
    end
  end

  defp publish_artifact(_config, _issue, artifact), do: {:ok, artifact}

  defp fetch_loop(config, cursor, acc, wanted_states) do
    query = """
    query($projectSlugId: String!, $after: String) {
      issues(filter: {project: {slugId: {eq: $projectSlugId}}}, first: #{@page_size}, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          identifier
          title
          description
          comments(first: 8) {
            nodes {
              id
              body
              createdAt
              updatedAt
              user { name }
            }
          }
          priority
          state { name }
          branchName
          url
          labels { nodes { name } }
          createdAt
          updatedAt
        }
      }
    }
    """

    vars = %{projectSlugId: config.tracker_project_slug, after: cursor}

    with {:ok, issues_page} <- execute_query(config, query, vars, &get_in(&1, ["data", "issues"])),
         {:ok, nodes, page_info} <- normalize_issues_page(issues_page) do
      normalized =
        nodes
        |> Enum.map(&Issue.from_payload/1)
        |> Enum.filter(fn issue ->
          Symphony.Issue.normalize_state(issue.state) in wanted_states
        end)

      next_acc = acc ++ normalized

      if Map.get(page_info, "hasNextPage") do
        fetch_loop(config, Map.get(page_info, "endCursor"), next_acc, wanted_states)
      else
        {:ok, next_acc}
      end
    end
  end

  defp normalize_issues_page(%{"nodes" => nodes, "pageInfo" => page_info})
       when is_list(nodes) and is_map(page_info) do
    {:ok, Enum.filter(nodes, &is_map/1), page_info}
  end

  defp normalize_issues_page(_), do: {:error, :malformed_graphql}

  defp execute_query(config, query, variables, normalize_fun) do
    body = Jason.encode!(%{query: query, variables: variables})

    headers = [
      {"authorization", auth_header_value(config.tracker_api_key)},
      {"content-type", "application/json"}
    ]

    request = Finch.build(:post, config.tracker_endpoint, headers, body)

    case Finch.request(request, Symphony.Finch, receive_timeout: max(1_000, config.read_timeout_ms)) do
      {:ok, %Finch.Response{status: 200, body: raw}} ->
        case Jason.decode(raw) do
          {:ok, decoded} ->
            if Map.get(decoded, "errors") do
              {:error, :graphql_errors}
            else
              {:ok, normalize_fun.(decoded)}
            end

          _ ->
            {:error, :malformed_graphql}
        end

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp create_file_upload(config, filename, size, content_type) do
    mutation = """
    mutation($contentType: String!, $filename: String!, $size: Int!) {
      fileUpload(contentType: $contentType, filename: $filename, size: $size) {
        success
        uploadFile {
          uploadUrl
          assetUrl
          headers {
            key
            value
          }
        }
      }
    }
    """

    with {:ok, payload} <-
           execute_query(
             config,
             mutation,
             %{contentType: content_type, filename: filename, size: size},
             &get_in(&1, ["data", "fileUpload"])
           ),
         true <- is_map(payload),
         true <- payload["success"] == true,
         {:ok, upload} <- normalize_upload_payload(payload["uploadFile"]) do
      {:ok, upload}
    else
      false -> {:error, :file_upload_init_failed}
      {:ok, _} -> {:error, :file_upload_init_failed}
      error -> error
    end
  end

  defp normalize_upload_payload(%{"uploadUrl" => upload_url, "assetUrl" => asset_url} = payload)
       when is_binary(upload_url) and is_binary(asset_url) do
    {:ok,
     %{
       upload_url: upload_url,
       asset_url: asset_url,
       headers: normalize_upload_headers(payload["headers"])
     }}
  end

  defp normalize_upload_payload(_), do: {:error, :file_upload_payload_missing}

  defp normalize_upload_headers(headers) when is_list(headers) do
    headers
    |> Enum.map(fn
      %{"key" => key, "value" => value} when is_binary(key) and is_binary(value) ->
        {String.downcase(key), value}

      %{key: key, value: value} when is_binary(key) and is_binary(value) ->
        {String.downcase(key), value}

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_upload_headers(_), do: []

  defp upload_file(upload, path, content_type) do
    headers =
      [{"content-type", content_type} | upload.headers]
      |> Enum.uniq_by(fn {key, _value} -> String.downcase(key) end)

    with {:ok, body} <- File.read(path) do
      request = Finch.build(:put, upload.upload_url, headers, body)

      case Finch.request(request, Symphony.Finch, receive_timeout: 60_000) do
        {:ok, %Finch.Response{status: status}} when status in 200..299 ->
          :ok

        {:ok, %Finch.Response{status: status, body: body}} ->
          {:error, {:file_upload_put_failed, status, body}}

        {:error, reason} ->
          {:error, {:file_upload_put_transport_failed, reason}}
      end
    end
  end

  defp create_attachment(config, %Issue{} = issue, asset_url, filename, subtitle) do
    mutation = """
    mutation($input: AttachmentCreateInput!) {
      attachmentCreate(input: $input) {
        success
        attachment {
          id
        }
      }
    }
    """

    variables = %{
      input: %{
        issueId: issue.id,
        title: filename,
        subtitle: subtitle,
        url: asset_url
      }
    }

    with {:ok, payload} <-
           execute_query(config, mutation, variables, &get_in(&1, ["data", "attachmentCreate"])),
         true <- is_map(payload),
         true <- payload["success"] == true,
         attachment_id when is_binary(attachment_id) and attachment_id != "" <-
           get_in(payload, ["attachment", "id"]) do
      {:ok, attachment_id}
    else
      false -> {:error, :attachment_create_failed}
      {:ok, _} -> {:error, :attachment_create_failed}
      _ -> {:error, :attachment_create_failed}
    end
  end

  defp maybe_create_comment(config, %Issue{} = issue, asset_url, filename) do
    if config.recording_publish_comment do
      create_comment(config, issue, asset_url, filename)
    else
      {:ok, nil}
    end
  end

  defp maybe_create_review_comment(config, %Issue{} = issue, review_artifact) do
    if config.recording_publish_comment do
      create_review_comment(config, issue, review_artifact)
    else
      {:ok, nil}
    end
  end

  defp create_review_comment(config, %Issue{} = issue, review_artifact) do
    mutation = """
    mutation($input: CommentCreateInput!) {
      commentCreate(input: $input) {
        success
        comment {
          id
        }
      }
    }
    """

    body =
      """
      Review handoff PR: [#{review_artifact[:pr_title] || review_artifact["pr_title"]}](#{review_artifact[:pr_url] || review_artifact["pr_url"]})

      Branch: `#{review_artifact[:branch] || review_artifact["branch"]}`
      Base: `#{review_artifact[:base_branch] || review_artifact["base_branch"]}`
      Commit: `#{review_artifact[:commit_sha] || review_artifact["commit_sha"]}`
      Auto-merge: #{if(review_artifact[:auto_merge_enabled] || review_artifact["auto_merge_enabled"], do: "enabled", else: "disabled")}
      Merged: #{if(review_artifact[:pr_merged] || review_artifact["pr_merged"], do: "yes", else: "no")}
      """
      |> String.trim()

    variables = %{input: %{issueId: issue.id, body: body}}

    with {:ok, payload} <-
           execute_query(config, mutation, variables, &get_in(&1, ["data", "commentCreate"])),
         true <- is_map(payload),
         true <- payload["success"] == true,
         comment_id when is_binary(comment_id) and comment_id != "" <-
           get_in(payload, ["comment", "id"]) do
      {:ok, comment_id}
    else
      false -> {:error, :review_comment_create_failed}
      {:ok, _} -> {:error, :review_comment_create_failed}
      _ -> {:error, :review_comment_create_failed}
    end
  end

  defp create_comment(config, %Issue{} = issue, asset_url, filename) do
    mutation = """
    mutation($input: CommentCreateInput!) {
      commentCreate(input: $input) {
        success
        comment {
          id
        }
      }
    }
    """

    body = "Recorded artifact uploaded to Linear storage: [#{filename}](#{asset_url})"
    variables = %{input: %{issueId: issue.id, body: body}}

    with {:ok, payload} <-
           execute_query(config, mutation, variables, &get_in(&1, ["data", "commentCreate"])),
         true <- is_map(payload),
         true <- payload["success"] == true,
         comment_id when is_binary(comment_id) and comment_id != "" <-
           get_in(payload, ["comment", "id"]) do
      {:ok, comment_id}
    else
      false -> {:error, :comment_create_failed}
      {:ok, _} -> {:error, :comment_create_failed}
      _ -> {:error, :comment_create_failed}
    end
  end

  defp transition_issue_state(config, issue_id, target_type) do
    with {:ok, issue} <- fetch_issue_state_details(config, issue_id),
         {:ok, current_type, state_id} <- choose_state_id(issue, target_type),
         :ok <- maybe_update_issue_state(config, issue_id, state_id, current_type, target_type) do
      :ok
    end
  end

  defp fetch_issue_state_details(config, issue_id) do
    query = """
    query($id: String!) {
      issue(id: $id) {
        id
        state { id name type }
        team {
          states {
            nodes { id name type }
          }
        }
      }
    }
    """

    execute_query(config, query, %{id: issue_id}, &get_in(&1, ["data", "issue"]))
  end

  defp choose_state_id(%{"state" => current_state, "team" => %{"states" => %{"nodes" => nodes}}}, target_type)
       when is_map(current_state) and is_list(nodes) do
    current_type = normalize_type(current_state["type"])

    preferred =
      case target_type do
        "in_review" -> choose_review_state(nodes)
        _ -> choose_typed_state(nodes, target_type)
      end

    if is_map(preferred) and is_binary(preferred["id"]) and String.trim(preferred["id"]) != "" do
      {:ok, current_type, preferred["id"]}
    else
      {:error, :target_state_not_found}
    end
  end

  defp choose_state_id(_, _), do: {:error, :issue_state_data_missing}

  defp choose_review_state(nodes) do
    nodes
    |> Enum.sort_by(fn node ->
      name = Symphony.Issue.normalize_state(node["name"] || "")
      type = normalize_type(node["type"])

      cond do
        name == "in review" -> 0
        name == "review" -> 1
        String.contains?(name || "", "review") -> 2
        type == "started" -> 3
        type == "completed" -> 4
        true -> 5
      end
    end)
    |> List.first()
  end

  defp choose_typed_state(nodes, target_type) do
    nodes
    |> Enum.filter(fn node -> normalize_type(node["type"]) == target_type end)
    |> Enum.sort_by(fn node ->
      name = Symphony.Issue.normalize_state(node["name"] || "")

      cond do
        target_type == "started" and name == "in progress" -> 0
        target_type == "completed" and name == "done" -> 0
        true -> 1
      end
    end)
    |> List.first()
  end

  defp maybe_update_issue_state(_config, _issue_id, _state_id, target_type, target_type), do: :ok

  defp maybe_update_issue_state(config, issue_id, state_id, _current_type, _target_type) do
    mutation = """
    mutation($id: String!, $stateId: String!) {
      issueUpdate(id: $id, input: { stateId: $stateId }) {
        success
      }
    }
    """

    with {:ok, payload} <-
           execute_query(config, mutation, %{id: issue_id, stateId: state_id}, &get_in(&1, ["data", "issueUpdate"])),
         true <- is_map(payload),
         true <- payload["success"] == true do
      :ok
    else
      false -> {:error, :state_update_failed}
      {:ok, _} -> {:error, :state_update_failed}
      error -> error
    end
  end

  defp normalize_state_set(states) do
    states
    |> List.wrap()
    |> Enum.map(&Symphony.Issue.normalize_state/1)
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  defp normalize_type(nil), do: nil

  defp normalize_type(value) when is_binary(value) do
    value |> String.trim() |> String.downcase()
  end

  defp normalize_type(_), do: nil

  defp auth_header_value(nil), do: ""

  defp auth_header_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace_prefix("Bearer ", "")
    |> String.replace_prefix("bearer ", "")
  end

  defp artifact_file_path(%{video_path: path}) when is_binary(path) and path != "", do: path
  defp artifact_file_path(%{"video_path" => path}) when is_binary(path) and path != "", do: path
  defp artifact_file_path(_), do: nil

  defp artifact_filename(path) when is_binary(path) do
    filename = Path.basename(path)

    if filename == "." or filename == "/" or String.trim(filename) == "" do
      {:error, :artifact_filename_missing}
    else
      {:ok, filename}
    end
  end

  defp content_type_for(path) do
    case path |> Path.extname() |> String.downcase() do
      ".mp4" -> {:ok, "video/mp4"}
      ".webm" -> {:ok, "video/webm"}
      ".mov" -> {:ok, "video/quicktime"}
      ".png" -> {:ok, "image/png"}
      ".jpg" -> {:ok, "image/jpeg"}
      ".jpeg" -> {:ok, "image/jpeg"}
      ext -> {:error, {:unsupported_artifact_content_type, ext}}
    end
  end
end
