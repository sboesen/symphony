defmodule Symphony.GitHubWebhookReconciler do
  @moduledoc false

  require Logger

  def desired_github_repos(sessions) do
    sessions
    |> List.wrap()
    |> Enum.map(fn session -> Map.get(session, :repo) || Map.get(session, "repo") end)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  def desired_linear_projects(sessions) do
    sessions
    |> List.wrap()
    |> Enum.map(fn session ->
      %{
        project_slug: Map.get(session, :project_slug) || Map.get(session, "project_slug"),
        session_id: Map.get(session, :session_id) || Map.get(session, "session_id")
      }
    end)
    |> Enum.filter(fn session ->
      is_binary(session.project_slug) and session.project_slug != "" and
        is_binary(session.session_id) and session.session_id != ""
    end)
    |> Enum.uniq_by(& &1.project_slug)
  end

  def reconcile_desired_github_hooks(current_hooks, repos, secret, callback, opts \\ []) do
    deps = deps(opts)

    next_hooks =
      Enum.reduce(Map.keys(current_hooks), current_hooks, fn repo, acc ->
        if repo in repos do
          acc
        else
          _ = deps.cleanup_github_webhook.(Map.get(acc, repo))
          Map.delete(acc, repo)
        end
      end)

    Enum.reduce_while(repos, {:ok, next_hooks}, fn repo, {:ok, acc} ->
      hook = Map.get(acc, repo)

      if hook && hook[:callback] == callback do
        {:cont, {:ok, acc}}
      else
        _ = deps.cleanup_github_webhook.(hook)
        _ = deps.cleanup_old_symphony_github_hooks.(repo)

        case deps.create_github_webhook.(repo, secret, callback) do
          {:ok, hook_id} ->
            deps.log_info.("registered GitHub webhook for #{repo} -> #{callback}")
            {:cont, {:ok, Map.put(acc, repo, %{id: hook_id, repo: repo, callback: callback})}}

          error ->
            {:halt, error}
        end
      end
    end)
  end

  def reconcile_desired_linear_hooks(current_hooks, desired_projects, secret, public_url, config, opts \\ []) do
    deps = deps(opts)

    next_hooks =
      Enum.reduce(Map.keys(current_hooks), current_hooks, fn slug, acc ->
        if Enum.any?(desired_projects, &(&1.project_slug == slug)) do
          acc
        else
          _ = deps.cleanup_linear_webhook.(config, Map.get(acc, slug))
          Map.delete(acc, slug)
        end
      end)

    Enum.reduce_while(desired_projects, {:ok, next_hooks}, fn project, {:ok, acc} ->
      callback = deps.linear_callback_url.(public_url, project.project_slug)
      hook = Map.get(acc, project.project_slug)

      if hook && hook[:callback] == callback do
        {:cont, {:ok, acc}}
      else
        _ = deps.cleanup_linear_webhook.(config, hook)
        _ = deps.cleanup_old_symphony_linear_hooks.(config, project.project_slug)

        case deps.create_linear_webhook.(config, project.project_slug, secret, callback) do
          {:ok, webhook} ->
            deps.log_info.("registered Linear webhook for #{project.project_slug} -> #{callback}")

            {:cont,
             {:ok,
              Map.put(acc, project.project_slug, %{
                id: webhook[:id],
                project_slug: project.project_slug,
                callback: callback
              })}}

          error ->
            {:halt, error}
        end
      end
    end)
  end

  def callback_url(public_url), do: public_url <> "/github/webhook"
  def linear_callback_url(public_url, project_slug), do: public_url <> "/linear/webhook/" <> project_slug

  defp deps(opts) do
    map = if is_map(opts), do: opts, else: Enum.into(opts, %{})

    Map.merge(
      %{
        cleanup_github_webhook: fn _ -> :ok end,
        cleanup_old_symphony_github_hooks: fn _ -> :ok end,
        create_github_webhook: fn _, _, _ -> {:error, :create_github_webhook_not_configured} end,
        cleanup_linear_webhook: fn _, _ -> :ok end,
        cleanup_old_symphony_linear_hooks: fn _, _ -> :ok end,
        create_linear_webhook: fn _, _, _, _ -> {:error, :create_linear_webhook_not_configured} end,
        linear_callback_url: &linear_callback_url/2,
        log_info: &Logger.info/1
      },
      map
    )
  end
end
