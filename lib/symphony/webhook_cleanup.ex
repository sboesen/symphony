defmodule Symphony.WebhookCleanup do
  @moduledoc "Best-effort external cleanup for Symphony-managed GitHub and Linear webhooks."

  def cleanup(%Symphony.Config{} = config, opts \\ []) do
    repo_slug = opts[:repo_slug]
    project_slug = opts[:project_slug]

    if is_binary(repo_slug) and repo_slug != "" do
      cleanup_github_hooks(repo_slug)
    end

    if is_binary(project_slug) and project_slug != "" do
      cleanup_linear_hooks(config, project_slug)
    end

    :ok
  end

  def cleanup_github_hooks(repo_slug) when is_binary(repo_slug) do
    with {output, 0} <-
           System.cmd("gh", ["api", "repos/#{repo_slug}/hooks"], stderr_to_stdout: true),
         {:ok, hooks} <- Jason.decode(output) do
      hooks
      |> Enum.filter(fn hook ->
        url = get_in(hook, ["config", "url"]) || ""
        String.contains?(url, "/api/v1/github/webhook") or String.contains?(url, "/github/webhook")
      end)
      |> Enum.each(fn hook ->
        _ =
          System.cmd(
            "gh",
            ["api", "--method", "DELETE", "repos/#{repo_slug}/hooks/#{hook["id"]}"],
            stderr_to_stdout: true
          )
      end)
    end

    :ok
  end

  def cleanup_github_hooks(_), do: :ok

  def cleanup_linear_hooks(%Symphony.Config{} = config, project_slug) when is_binary(project_slug) do
    with {:ok, webhooks} <- direct_webhooks(config) do
      slug = String.trim(project_slug)

      webhooks
      |> Enum.filter(fn hook ->
        url = hook[:url] || ""
        label = hook[:label] || ""

        String.contains?(url, "/linear/webhook/#{slug}") or
          String.contains?(url, "/api/v1/linear/webhook/#{slug}") or
          String.contains?(label, "(#{slug})")
      end)
      |> Enum.each(fn hook ->
        _ = direct_delete_webhook(config, hook.id)
      end)
    end

    :ok
  end

  def cleanup_linear_hooks(_, _), do: :ok

  defp direct_webhooks(%Symphony.Config{} = config) do
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

    with {:ok, payload} <- direct_query(config, query, %{}) do
      webhooks =
        get_in(payload, ["data", "webhooks", "nodes"])
        |> List.wrap()
        |> Enum.map(fn hook ->
          %{
            id: hook["id"],
            label: hook["label"],
            url: hook["url"],
            enabled: hook["enabled"] || false,
            team_id: get_in(hook, ["team", "id"]),
            team_key: get_in(hook, ["team", "key"]),
            team_name: get_in(hook, ["team", "name"])
          }
        end)

      {:ok, webhooks}
    end
  end

  defp direct_delete_webhook(%Symphony.Config{} = config, hook_id) when is_binary(hook_id) do
    mutation = "mutation($id: String!) { webhookDelete(id: $id) { success } }"

    with {:ok, payload} <- direct_query(config, mutation, %{id: hook_id}),
         %{"data" => %{"webhookDelete" => %{"success" => true}}} <- payload do
      :ok
    else
      _ -> :ok
    end
  end

  defp direct_query(%Symphony.Config{} = config, query, variables) do
    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)

    body = Jason.encode!(%{query: query, variables: variables})

    headers = [
      {~c"authorization", String.to_charlist(to_string(config.tracker_api_key || ""))},
      {~c"content-type", ~c"application/json"}
    ]

    request = {
      String.to_charlist(config.tracker_endpoint),
      headers,
      ~c"application/json",
      String.to_charlist(body)
    }

    case :httpc.request(:post, request, [], []) do
      {:ok, {{_, 200, _}, _resp_headers, resp_body}} ->
        case Jason.decode(IO.iodata_to_binary(resp_body)) do
          {:ok, %{"errors" => errors}} -> {:error, {:graphql_errors, errors}}
          {:ok, decoded} -> {:ok, decoded}
          _ -> {:error, :malformed_graphql}
        end

      {:ok, {{_, status, _}, _resp_headers, resp_body}} ->
        {:error, {:http_error, status, IO.iodata_to_binary(resp_body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
