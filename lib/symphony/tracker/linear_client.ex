defmodule Symphony.Tracker.LinearClient do
  @moduledoc "Linear GraphQL API client used by the orchestrator."

  alias Symphony.ProjectMetadata
  alias Symphony.Issue
  require Logger

  @recording_comment_tag "[Symphony:recording]"
  @recording_comment_marker "<!-- symphony-recording -->"
  @page_size 100
  @recording_comment_footer "_Symphony recording artifact._"
  @review_comment_tag "[Symphony:review]"
  @review_comment_marker "<!-- symphony-review -->"
  @review_comment_footer "_Symphony review handoff._"
  @clarification_comment_marker "<!-- symphony-clarification -->"

  def fetch_candidates(config) do
    fetch_by_states(config, config.tracker_active_states)
  end

  def list_projects(config) do
    query = """
    query {
      projects(first: 50) {
        nodes {
          id
          name
          slugId
          description
          state
          teams {
            nodes {
              id
              key
              name
            }
          }
        }
      }
    }
    """

    with {:ok, payload} <-
           execute_query(config, query, %{}, &get_in(&1, ["data", "projects", "nodes"])) do
      {:ok, Enum.map(List.wrap(payload), &normalize_project/1)}
    end
  end

  def fetch_project_by_slug(config, slug) when is_binary(slug) do
    with {:ok, projects} <- list_projects(config) do
      normalized_slug = String.trim(slug)
      {:ok, Enum.find(projects, fn project -> project.slug_id == normalized_slug end)}
    end
  end

  def save_project_repo(config, project, repo_url) when is_map(project) and is_binary(repo_url) do
    mutation = """
    mutation($id: String!, $input: ProjectUpdateInput!) {
      projectUpdate(id: $id, input: $input) {
        success
        project {
          id
          name
          slugId
          description
          state
          teams {
            nodes {
              key
              name
            }
          }
        }
      }
    }
    """

    description =
      ProjectMetadata.upsert_repo(project[:description] || project["description"], repo_url)

    variables = %{id: project[:id] || project["id"], input: %{description: description}}

    with {:ok, payload} <-
           execute_query(config, mutation, variables, &get_in(&1, ["data", "projectUpdate"])),
         true <- is_map(payload),
         true <- payload["success"] == true,
         updated when is_map(updated) <- payload["project"] do
      {:ok, normalize_project(updated)}
    else
      false -> {:error, :project_update_failed}
      {:ok, _} -> {:error, :project_update_failed}
      error -> error
    end
  end

  def list_webhooks(config) do
    query = """
    query {
      webhooks(first: 100) {
        nodes {
          id
          label
          url
          enabled
          team {
            id
            key
            name
          }
        }
      }
    }
    """

    with {:ok, payload} <-
           execute_query(config, query, %{}, &get_in(&1, ["data", "webhooks", "nodes"])) do
      {:ok, Enum.map(List.wrap(payload), &normalize_webhook/1)}
    end
  end

  def create_webhook(config, attrs) when is_map(attrs) do
    mutation = """
    mutation($input: WebhookCreateInput!) {
      webhookCreate(input: $input) {
        success
        webhook {
          id
          label
          url
          enabled
          team {
            id
            key
            name
          }
        }
      }
    }
    """

    with {:ok, payload} <-
           execute_query(
             config,
             mutation,
             %{input: attrs},
             &get_in(&1, ["data", "webhookCreate"])
           ),
         true <- is_map(payload),
         true <- payload["success"] == true,
         webhook when is_map(webhook) <- payload["webhook"] do
      {:ok, normalize_webhook(webhook)}
    else
      false -> {:error, :linear_webhook_create_failed}
      {:ok, _} -> {:error, :linear_webhook_create_failed}
      error -> error
    end
  end

  def delete_webhook(config, webhook_id) when is_binary(webhook_id) do
    mutation = """
    mutation($id: String!) {
      webhookDelete(id: $id) {
        success
      }
    }
    """

    with {:ok, payload} <-
           execute_query(
             config,
             mutation,
             %{id: webhook_id},
             &get_in(&1, ["data", "webhookDelete"])
           ),
         true <- is_map(payload),
         true <- payload["success"] == true do
      {:ok, %{id: webhook_id}}
    else
      false -> {:error, :linear_webhook_delete_failed}
      {:ok, _} -> {:error, :linear_webhook_delete_failed}
      error -> error
    end
  end

  def mark_started(config, issue_id) do
    transition_issue_state(config, issue_id, "started")
  end

  def mark_todo(config, issue_id) do
    transition_issue_state(config, issue_id, "unstarted")
  end

  def mark_backlog(config, issue_id) do
    transition_issue_state(config, issue_id, "backlog")
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

  def publish_clarification(config, %Issue{} = issue, body, preferred_comment_id \\ nil)
      when is_binary(body) do
    case String.trim(body) do
      "" ->
        {:error, :clarification_body_missing}

      trimmed ->
        comment = clarification_comment_body(trimmed)

        case resolve_clarification_comment(config, issue, preferred_comment_id) do
          nil ->
            with {:ok, comment_id} <- create_plain_comment(config, issue.id, comment) do
              {:ok, %{comment_id: comment_id, body: comment, action: :created}}
            end

          existing ->
            with {:ok, comment_id} <- update_comment(config, existing.id, comment) do
              {:ok, %{comment_id: comment_id, body: comment, action: :updated}}
            end
        end
    end
  end

  defp clarification_comment_body(trimmed) do
    """
    Clarification needed before continuing:

    #{trimmed}

    #{@clarification_comment_marker}
    """
    |> String.trim()
  end

  def publish_review_handoff(config, %Issue{} = issue, review_artifact)
      when is_map(review_artifact) do
    with pr_url when is_binary(pr_url) <- review_artifact[:pr_url] || review_artifact["pr_url"],
         pr_title <- review_artifact[:pr_title] || review_artifact["pr_title"] || "Review PR",
         {:ok, attachment_id} <- upsert_review_attachment(config, issue, pr_url, pr_title),
         {:ok, comment_id} <- maybe_upsert_review_comment(config, issue, review_artifact) do
      {:ok,
       review_artifact
       |> Map.put(:linear_attachment_id, attachment_id)
       |> Map.put(:linear_comment_id, comment_id)}
    else
      nil -> {:ok, review_artifact}
      {:error, reason} -> {:error, reason}
    end
  end

  def publish_review_handoff(_config, %Issue{} = _issue, nil), do: {:ok, nil}

  def upsert_workpad(config, %Issue{} = issue, body, preferred_comment_id \\ nil)
      when is_binary(body) do
    body = String.trim(body)

    if body == "" do
      {:error, :workpad_body_missing}
    else
      case resolve_workpad_comment(config, issue, preferred_comment_id) do
        nil ->
          with {:ok, comment_id} <- create_plain_comment(config, issue.id, body) do
            {:ok, %{comment_id: comment_id, body: body, action: :created}}
          end

        comment ->
          with {:ok, comment_id} <- update_comment(config, comment.id, body) do
            {:ok, %{comment_id: comment_id, body: body, action: :updated}}
          end
      end
    end
  end

  def fetch_issue_by_identifier(config, identifier) when is_binary(identifier) do
    with {:ok, %{team_key: team_key, number: number}} <- parse_issue_identifier(identifier) do
      query = """
      query($teamKey: String!, $number: Float!) {
        issues(filter: { team: { key: { eq: $teamKey } }, number: { eq: $number } }, first: 1) {
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
             execute_query(
               config,
               query,
               %{teamKey: team_key, number: number},
               &get_in(&1, ["data", "issues", "nodes"])
             ),
           [issue | _] <- payload do
        {:ok, Issue.from_payload(issue)}
      else
        [] -> {:ok, nil}
        {:error, _} = error -> error
        _ -> {:error, :malformed_graphql}
      end
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
             {:ok, comment_id} <-
               maybe_upsert_recording_comment(config, issue, upload.asset_url, filename) do
          {:ok,
           artifact
           |> Map.put(:published, true)
           |> Map.put(:published_to, "linear")
           |> Map.put(:linear_asset_url, upload.asset_url)
           |> Map.put(:linear_attachment_id, nil)
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

  defp normalize_project(project) when is_map(project) do
    metadata = ProjectMetadata.parse(project["description"] || project[:description])

    %{
      id: project["id"] || project[:id],
      name: project["name"] || project[:name],
      slug_id: project["slugId"] || project[:slugId] || project["slug_id"],
      description: project["description"] || project[:description] || "",
      state: project["state"] || project[:state],
      team_keys:
        project
        |> get_in(["teams", "nodes"])
        |> Kernel.||(get_in(project, [:teams, :nodes]) || [])
        |> Enum.map(fn team -> team["key"] || team[:key] || team["name"] || team[:name] end)
        |> Enum.filter(&is_binary/1),
      team_ids:
        project
        |> get_in(["teams", "nodes"])
        |> Kernel.||(get_in(project, [:teams, :nodes]) || [])
        |> Enum.map(fn team -> team["id"] || team[:id] end)
        |> Enum.filter(&is_binary/1),
      repo_url: metadata.repo_url
    }
  end

  defp normalize_webhook(webhook) when is_map(webhook) do
    %{
      id: webhook["id"] || webhook[:id],
      label: webhook["label"] || webhook[:label],
      url: webhook["url"] || webhook[:url],
      enabled: webhook["enabled"] || webhook[:enabled] || false,
      team_id: get_in(webhook, ["team", "id"]) || get_in(webhook, [:team, :id]),
      team_key: get_in(webhook, ["team", "key"]) || get_in(webhook, [:team, :key]),
      team_name: get_in(webhook, ["team", "name"]) || get_in(webhook, [:team, :name])
    }
  end

  defp execute_query(config, query, variables, normalize_fun) do
    body = Jason.encode!(%{query: query, variables: variables})

    headers = [
      {"authorization", auth_header_value(config.tracker_api_key)},
      {"content-type", "application/json"}
    ]

    request = Finch.build(:post, config.tracker_endpoint, headers, body)

    case Finch.request(request, Symphony.Finch,
           receive_timeout: max(1_000, config.read_timeout_ms)
         ) do
      {:ok, %Finch.Response{status: 200, body: raw}} ->
        case Jason.decode(raw) do
          {:ok, decoded} ->
            if Map.get(decoded, "errors") do
              graphql_error(Map.get(decoded, "errors"))
            else
              {:ok, normalize_fun.(decoded)}
            end

          _ ->
            {:error, :malformed_graphql}
        end

      {:ok, %Finch.Response{status: status, body: raw}} ->
        case Jason.decode(raw) do
          {:ok, decoded} ->
            case decoded do
              %{"errors" => errors} when is_list(errors) ->
                graphql_error(errors)

              _ ->
                {:error, {:http_error, status, raw}}
            end

          _ ->
            {:error, {:http_error, status, raw}}
        end

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp graphql_error(errors) when is_list(errors) do
    if Enum.any?(errors, &rate_limited_graphql_error?/1) do
      {:error, :rate_limited}
    else
      {:error, {:graphql_errors, errors}}
    end
  end

  defp graphql_error(_), do: {:error, :graphql_errors}

  defp rate_limited_graphql_error?(%{"extensions" => %{"code" => code}})
       when is_binary(code) do
    String.upcase(String.trim(code)) == "RATELIMITED"
  end

  defp rate_limited_graphql_error?(%{"message" => message}) when is_binary(message) do
    String.contains?(String.downcase(message), "rate limit")
  end

  defp rate_limited_graphql_error?(_), do: false

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

  defp maybe_upsert_recording_comment(config, %Issue{} = issue, asset_url, filename) do
    if config.recording_publish_comment do
      body = recording_comment_body(asset_url, filename)

      case find_recording_comment(config, issue) do
        nil -> create_plain_comment(config, issue.id, body)
        comment -> update_comment(config, comment.id, body)
      end
    else
      {:ok, nil}
    end
  end

  defp maybe_upsert_review_comment(config, %Issue{} = issue, review_artifact) do
    if config.recording_publish_comment do
      body = review_comment_body(review_artifact)

      case find_review_comment(config, issue, review_artifact) do
        nil -> create_plain_comment(config, issue.id, body)
        comment -> update_comment(config, comment.id, body)
      end
    else
      {:ok, nil}
    end
  end

  defp find_workpad_comment(%Issue{} = issue) do
    issue.comments
    |> List.wrap()
    |> Enum.filter(fn comment ->
      body = comment.body || ""

      String.contains?(body, Symphony.PlanContract.workpad_tag()) ||
        String.contains?(body, Symphony.PlanContract.workpad_marker()) ||
        String.contains?(body, Symphony.PlanContract.workpad_footer())
    end)
    |> Enum.max_by(&comment_timestamp/1, fn -> nil end)
  end

  defp find_recording_comment(config, %Issue{} = issue) do
    issue
    |> resolve_issue_comments(config)
    |> Enum.filter(fn comment ->
      body = comment.body || ""

      String.contains?(body, @recording_comment_tag) or
        String.contains?(body, @recording_comment_marker) or
        String.contains?(body, @recording_comment_footer) or
        String.match?(body, ~r/^https:\/\/uploads\.linear\.app\/\S+$/)
    end)
    |> Enum.max_by(&comment_timestamp/1, fn -> nil end)
  end

  defp find_review_comment(config, %Issue{} = issue, review_artifact) do
    pr_url = review_artifact[:pr_url] || review_artifact["pr_url"] || ""

    issue
    |> resolve_issue_comments(config)
    |> Enum.filter(fn comment ->
      body = comment.body || ""

      (String.contains?(body, @review_comment_tag) or
         String.contains?(body, @review_comment_marker) or
         String.contains?(body, @review_comment_footer) or
         String.contains?(body, "Review handoff PR:")) and
        (pr_url == "" or String.contains?(body, pr_url))
    end)
    |> Enum.max_by(&comment_timestamp/1, fn -> nil end)
  end

  defp find_clarification_comment(config, %Issue{} = issue) do
    issue
    |> resolve_issue_comments(config)
    |> Enum.filter(fn comment ->
      body = comment.body || ""

      String.contains?(body, @clarification_comment_marker) or
        String.starts_with?(String.trim_leading(body), "Clarification needed before continuing:")
    end)
    |> Enum.max_by(&comment_timestamp/1, fn -> nil end)
  end

  defp resolve_clarification_comment(config, %Issue{} = issue, preferred_comment_id) do
    cond do
      is_binary(preferred_comment_id) and String.trim(preferred_comment_id) != "" ->
        %{id: preferred_comment_id}

      true ->
        find_clarification_comment(config, issue)
    end
  end

  defp resolve_issue_comments(%Issue{} = issue, config) do
    case fetch_issue_comments(config, issue.id) do
      {:ok, fresh_issue} ->
        Issue.from_payload(fresh_issue, include_managed_comments: true).comments || []

      _ ->
        issue.comments || []
    end
  end

  defp resolve_workpad_comment(config, %Issue{} = issue, preferred_comment_id) do
    cond do
      is_binary(preferred_comment_id) and String.trim(preferred_comment_id) != "" ->
        %{id: preferred_comment_id}

      true ->
        case fetch_issue_comments(config, issue.id) do
          {:ok, fresh_issue} ->
            find_workpad_comment(Issue.from_payload(fresh_issue, include_managed_comments: true))

          _ ->
            find_workpad_comment(issue)
        end
    end
  end

  defp create_plain_comment(config, issue_id, body) when is_binary(body) do
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

    variables = %{input: %{issueId: issue_id, body: body}}

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

  defp update_comment(config, comment_id, body) do
    mutation = """
    mutation($id: String!, $input: CommentUpdateInput!) {
      commentUpdate(id: $id, input: $input) {
        success
        comment {
          id
        }
      }
    }
    """

    variables = %{id: comment_id, input: %{body: body}}

    with {:ok, payload} <-
           execute_query(config, mutation, variables, &get_in(&1, ["data", "commentUpdate"])),
         true <- is_map(payload),
         true <- payload["success"] == true,
         returned_id when is_binary(returned_id) and returned_id != "" <-
           get_in(payload, ["comment", "id"]) do
      {:ok, returned_id}
    else
      false -> {:error, :comment_update_failed}
      {:ok, _} -> {:error, :comment_update_failed}
      _ -> {:error, :comment_update_failed}
    end
  end

  defp transition_issue_state(config, issue_id, target_type) do
    with {:ok, issue} <- fetch_issue_state_details(config, issue_id),
         {:ok, current_type, state_id} <- choose_state_id(issue, target_type),
         :ok <- maybe_update_issue_state(config, issue_id, state_id, current_type, target_type),
         :ok <- confirm_issue_state(config, issue_id, target_type) do
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

  defp fetch_issue_comments(config, issue_id) do
    query = """
    query($id: String!) {
      issue(id: $id) {
        id
        comments(first: 50) {
          nodes {
            id
            body
            createdAt
            updatedAt
            user { name }
          }
        }
      }
    }
    """

    execute_query(config, query, %{id: issue_id}, &get_in(&1, ["data", "issue"]))
  end

  defp list_attachments(config, %Issue{} = issue) do
    query = """
    query($id: String!) {
      issue(id: $id) {
        attachments(first: 50) {
          nodes {
            id
            title
            subtitle
            url
          }
        }
      }
    }
    """

    with {:ok, payload} <-
           execute_query(
             config,
             query,
             %{id: issue.id},
             &get_in(&1, ["data", "issue", "attachments", "nodes"])
           ) do
      {:ok, List.wrap(payload)}
    end
  end

  defp upsert_review_attachment(config, %Issue{} = issue, pr_url, pr_title) do
    case find_review_attachment(config, issue, pr_url) do
      {:ok, attachment_id} -> {:ok, attachment_id}
      :not_found -> create_attachment(config, issue, pr_url, pr_title, "Symphony review PR")
    end
  end

  defp find_review_attachment(config, %Issue{} = issue, pr_url) do
    with {:ok, attachments} <- list_attachments(config, issue),
         attachment when is_map(attachment) <-
           Enum.find(attachments, fn attachment ->
             (attachment["url"] || attachment[:url]) == pr_url and
               String.contains?(
                 attachment["subtitle"] || attachment[:subtitle] || "",
                 "Symphony review PR"
               )
           end),
         attachment_id when is_binary(attachment_id) and attachment_id != "" <-
           attachment["id"] || attachment[:id] do
      {:ok, attachment_id}
    else
      _ -> :not_found
    end
  end

  defp choose_state_id(
         %{"state" => current_state, "team" => %{"states" => %{"nodes" => nodes}}},
         target_type
       )
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
           execute_query(
             config,
             mutation,
             %{id: issue_id, stateId: state_id},
             &get_in(&1, ["data", "issueUpdate"])
           ),
         true <- is_map(payload),
         true <- payload["success"] == true do
      :ok
    else
      false -> {:error, :state_update_failed}
      {:ok, _} -> {:error, :state_update_failed}
      error -> error
    end
  end

  defp confirm_issue_state(config, issue_id, target_type) do
    confirm_issue_state(config, issue_id, target_type, 12)
  end

  defp confirm_issue_state(_config, _issue_id, _target_type, 0),
    do: {:error, :state_confirmation_failed}

  defp confirm_issue_state(config, issue_id, target_type, attempts_left) do
    case fetch_issue_state_details(config, issue_id) do
      {:ok, %{"state" => state}} when is_map(state) ->
        if state_matches_target?(state, target_type) do
          :ok
        else
          Process.sleep(250)
          confirm_issue_state(config, issue_id, target_type, attempts_left - 1)
        end

      {:ok, _} ->
        Process.sleep(250)
        confirm_issue_state(config, issue_id, target_type, attempts_left - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp state_matches_target?(state, "in_review") when is_map(state) do
    name = Symphony.Issue.normalize_state(state["name"] || "")
    type = normalize_type(state["type"])

    name in ["in review", "review"] or String.contains?(name || "", "review") or
      type == "in_review"
  end

  defp state_matches_target?(state, target_type) when is_map(state) do
    normalize_type(state["type"]) == target_type
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

  defp comment_timestamp(comment) when is_map(comment) do
    comment.created_at || comment.updated_at || ~U[1970-01-01 00:00:00Z]
  end

  defp auth_header_value(nil), do: ""

  defp auth_header_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace_prefix("Bearer ", "")
    |> String.replace_prefix("bearer ", "")
  end

  defp artifact_file_path(%{video_path: path}) when is_binary(path) and path != "", do: path
  defp artifact_file_path(%{"video_path" => path}) when is_binary(path) and path != "", do: path
  defp artifact_file_path(%{raw_video_path: path}) when is_binary(path) and path != "", do: path

  defp artifact_file_path(%{"raw_video_path" => path}) when is_binary(path) and path != "",
    do: path

  defp artifact_file_path(%{screenshot_path: path}) when is_binary(path) and path != "", do: path

  defp artifact_file_path(%{"screenshot_path" => path}) when is_binary(path) and path != "",
    do: path

  defp artifact_file_path(_), do: nil

  defp recording_comment_body(asset_url, filename) do
    case Path.extname(filename || "") |> String.downcase() do
      ext when ext in [".png", ".jpg", ".jpeg", ".gif", ".webp"] ->
        """
        ![#{filename}](#{asset_url})

        #{@recording_comment_marker}
        """
        |> String.trim()

      ext when ext in [".webm", ".mp4", ".mov"] ->
        """
        #{asset_url}

        #{@recording_comment_marker}
        """
        |> String.trim()

      _ ->
        """
        Recorded artifact uploaded to Linear storage: [#{filename}](#{asset_url})

        #{@recording_comment_marker}
        """
        |> String.trim()
    end
  end

  defp review_comment_body(review_artifact) do
    """
    Review handoff PR: [#{review_artifact[:pr_title] || review_artifact["pr_title"]}](#{review_artifact[:pr_url] || review_artifact["pr_url"]})

    Branch: `#{review_artifact[:branch] || review_artifact["branch"]}`
    Base: `#{review_artifact[:base_branch] || review_artifact["base_branch"]}`
    Commit: `#{review_artifact[:commit_sha] || review_artifact["commit_sha"]}`
    Auto-merge: #{if(review_artifact[:auto_merge_enabled] || review_artifact["auto_merge_enabled"], do: "enabled", else: "disabled")}
    Merged: #{if(review_artifact[:pr_merged] || review_artifact["pr_merged"], do: "yes", else: "no")}

    #{@review_comment_marker}
    """
    |> String.trim()
  end

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

  defp parse_issue_identifier(identifier) when is_binary(identifier) do
    case Regex.run(~r/\A([A-Z][A-Z0-9]+)-(\d+)\z/, String.trim(identifier),
           capture: :all_but_first
         ) do
      [team_key, number_text] ->
        {:ok, %{team_key: team_key, number: String.to_integer(number_text)}}

      _ ->
        {:error, :invalid_issue_identifier}
    end
  end
end
