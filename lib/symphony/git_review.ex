defmodule Symphony.GitReview do
  @moduledoc "Prepares per-issue branches and creates or updates GitHub pull requests via git + gh."

  alias Symphony.Issue

  @default_commit_author_name "Symphony"
  @default_commit_author_email "symphony@local"

  def prepare_workspace(%Issue{} = issue, workspace_path, config) do
    if enabled?(config) and git_repo?(workspace_path) do
      with {:ok, branch} <- review_branch(issue),
           {:ok, base_branch} <- base_branch(workspace_path, config),
           :ok <- ensure_identity(workspace_path),
           :ok <- checkout_review_branch(workspace_path, branch, base_branch),
           {:ok, repo_slug} <- repo_slug(workspace_path) do
        {:ok,
         %{
           branch: branch,
           base_branch: base_branch,
           repo_slug: repo_slug,
           draft: config.review_pr_draft
         }}
      end
    else
      {:ok, nil}
    end
  end

  def open_review_pr(%Issue{} = issue, workspace_path, config, branch_info) do
    if enabled?(config) and is_map(branch_info) do
      with {:ok, repo_slug} <- repo_slug(workspace_path),
           {:ok, commit_sha, changed?} <- commit_and_push(issue, workspace_path, branch_info),
           {:ok, pr} <- ensure_pull_request(issue, workspace_path, repo_slug, branch_info, changed?),
           {:ok, merge_state} <-
             maybe_enable_auto_merge(workspace_path, repo_slug, pr.number, config) do
        {:ok,
         %{
           kind: "pull_request",
           status: "ready",
           pr_title: pr_title(issue),
           branch: branch_info.branch,
           base_branch: branch_info.base_branch,
           repo_slug: repo_slug,
           commit_sha: commit_sha,
           changed: changed?,
           pr_number: pr.number,
           pr_url: pr.url,
           pr_created: pr.created,
           auto_merge_enabled: merge_state.auto_merge_enabled,
           pr_merged: merge_state.pr_merged
         }}
      end
    else
      {:ok, nil}
    end
  end

  def enabled?(config) do
    config.review_pr_enabled == true
  end

  defp git_repo?(workspace_path) do
    case run_git(workspace_path, ["rev-parse", "--is-inside-work-tree"]) do
      {:ok, "true"} -> true
      _ -> false
    end
  end

  defp review_branch(%Issue{} = issue) do
    branch =
      issue.branch_name ||
        "symphony/#{sanitize_branch_component(issue.identifier)}"

    normalized =
      branch
      |> String.trim()
      |> String.replace(~r/\s+/, "-")
      |> String.replace(~r/[^A-Za-z0-9._\/-]/, "-")

    if normalized == "" do
      {:error, :review_branch_missing}
    else
      {:ok, normalized}
    end
  end

  defp sanitize_branch_component(nil), do: "issue"

  defp sanitize_branch_component(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]/, "-")
  end

  defp base_branch(workspace_path, config) do
    preferred =
      [config.review_pr_base_branch, detect_origin_head(workspace_path), current_branch(workspace_path), "main"]
      |> Enum.find(&is_binary/1)

    {:ok, preferred}
  end

  defp detect_origin_head(workspace_path) do
    case run_git(workspace_path, ["symbolic-ref", "refs/remotes/origin/HEAD"]) do
      {:ok, ref} ->
        ref
        |> String.split("/", trim: true)
        |> List.last()

      _ ->
        nil
    end
  end

  defp current_branch(workspace_path) do
    case run_git(workspace_path, ["branch", "--show-current"]) do
      {:ok, ""} -> nil
      {:ok, branch} -> branch
      _ -> nil
    end
  end

  defp ensure_identity(workspace_path) do
    with :ok <- ensure_git_config(workspace_path, "user.name", @default_commit_author_name),
         :ok <- ensure_git_config(workspace_path, "user.email", @default_commit_author_email) do
      :ok
    end
  end

  defp ensure_git_config(workspace_path, key, default_value) do
    case run_git(workspace_path, ["config", "--get", key]) do
      {:ok, value} when value != "" -> :ok
      _ ->
        case run_git(workspace_path, ["config", key, default_value]) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp checkout_review_branch(workspace_path, branch, base_branch) do
    if current_branch(workspace_path) == branch do
      :ok
    else
    remote_exists? =
      case run_git(workspace_path, ["ls-remote", "--heads", "origin", branch]) do
        {:ok, output} -> String.trim(output) != ""
        _ -> false
      end

      cond do
        remote_exists? ->
          with {:ok, _} <- run_git(workspace_path, ["fetch", "origin", branch]),
               {:ok, _} <- run_git(workspace_path, ["checkout", "-B", branch, "origin/" <> branch]) do
            :ok
          end

        true ->
          _ = run_git(workspace_path, ["fetch", "origin", base_branch])

          base_ref =
            case run_git(workspace_path, ["rev-parse", "--verify", "origin/" <> base_branch]) do
              {:ok, _} -> "origin/" <> base_branch
              _ -> "HEAD"
            end

          case run_git(workspace_path, ["checkout", "-B", branch, base_ref]) do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  defp commit_and_push(%Issue{} = issue, workspace_path, branch_info) do
    with {:ok, _} <- run_git(workspace_path, ["add", "-A"]),
         {:ok, changed?} <- staged_changes?(workspace_path),
         {:ok, commit_sha} <- maybe_commit(issue, workspace_path, changed?),
         {:ok, _} <- run_git(workspace_path, ["push", "-u", "origin", branch_info.branch]) do
      {:ok, commit_sha, changed?}
    end
  end

  defp staged_changes?(workspace_path) do
    case run_git(workspace_path, ["diff", "--cached", "--quiet", "--exit-code"]) do
      {:ok, _} -> {:ok, false}
      {:error, {:exit_status, 1, _}} -> {:ok, true}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_commit(%Issue{} = issue, workspace_path, true) do
    message = "#{issue.identifier}: #{issue.title}"

    with {:ok, _} <- run_git(workspace_path, ["commit", "-m", message]),
         {:ok, sha} <- run_git(workspace_path, ["rev-parse", "HEAD"]) do
      {:ok, sha}
    end
  end

  defp maybe_commit(_issue, workspace_path, false) do
    case run_git(workspace_path, ["rev-parse", "HEAD"]) do
      {:ok, sha} -> {:ok, sha}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_pull_request(%Issue{} = issue, workspace_path, repo_slug, branch_info, changed?) do
    case find_existing_pr(workspace_path, repo_slug, branch_info.branch) do
      {:ok, pr} ->
        _ = update_pr(workspace_path, repo_slug, pr.number, issue, branch_info, changed?)
        {:ok, Map.put(pr, :created, false)}

      {:error, :pr_not_found} ->
        create_pr(workspace_path, repo_slug, issue, branch_info, changed?)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_existing_pr(workspace_path, repo_slug, branch) do
    case run_gh(workspace_path, [
           "pr",
           "list",
           "--repo",
           repo_slug,
           "--head",
           branch,
           "--state",
           "open",
           "--json",
           "number,url"
         ]) do
      {:ok, raw} ->
        with {:ok, decoded} <- Jason.decode(raw),
             [first | _] <- decoded do
          {:ok, %{number: first["number"], url: first["url"]}}
        else
          [] -> {:error, :pr_not_found}
          _ -> {:error, :pr_lookup_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_pr(workspace_path, repo_slug, %Issue{} = issue, branch_info, changed?) do
    args = [
      "pr",
      "create",
      "--repo",
      repo_slug,
      "--base",
      branch_info.base_branch,
      "--head",
      branch_info.branch,
      "--title",
      pr_title(issue),
      "--body",
      pr_body(issue, branch_info, changed?)
    ]

    args =
      if branch_info[:draft] do
        args ++ ["--draft"]
      else
        args
      end

    case run_gh(workspace_path, args) do
      {:ok, url} ->
        pr_number = parse_pr_number(url)
        {:ok, %{number: pr_number, url: url, created: true}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_pr(workspace_path, repo_slug, pr_number, %Issue{} = issue, branch_info, changed?) do
    _ =
      run_gh(workspace_path, [
        "pr",
        "edit",
        Integer.to_string(pr_number),
        "--repo",
        repo_slug,
        "--title",
        pr_title(issue),
        "--body",
        pr_body(issue, branch_info, changed?)
      ])

    :ok
  end

  defp maybe_enable_auto_merge(_workspace_path, _repo_slug, _pr_number, config)
       when config.review_pr_auto_merge != true do
    {:ok, %{auto_merge_enabled: false, pr_merged: false}}
  end

  defp maybe_enable_auto_merge(_workspace_path, _repo_slug, _pr_number, %{review_pr_draft: true}) do
    {:ok, %{auto_merge_enabled: false, pr_merged: false}}
  end

  defp maybe_enable_auto_merge(workspace_path, repo_slug, pr_number, _config) do
    case run_gh(workspace_path, [
           "pr",
           "merge",
           Integer.to_string(pr_number),
           "--repo",
           repo_slug,
           "--auto",
           "--squash"
         ]) do
      {:ok, _} ->
        with {:ok, merged?} <- pr_merged?(workspace_path, repo_slug, pr_number) do
          {:ok, %{auto_merge_enabled: true, pr_merged: merged?}}
        end

      {:error, {:exit_status, _status, output}} when is_binary(output) ->
        if String.contains?(String.downcase(output), "auto-merge is not enabled") or
             String.contains?(String.downcase(output), "not supported") or
             String.contains?(String.downcase(output), "clean status") or
             String.contains?(output, "enablePullRequestAutoMerge") do
          merge_now(workspace_path, repo_slug, pr_number)
        else
          {:error, {:auto_merge_failed, output}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp pr_merged?(workspace_path, repo_slug, pr_number) do
    case run_gh(workspace_path, [
           "pr",
           "view",
           Integer.to_string(pr_number),
           "--repo",
           repo_slug,
           "--json",
           "mergedAt"
         ]) do
      {:ok, raw} ->
        with {:ok, decoded} <- Jason.decode(raw) do
          {:ok, is_binary(decoded["mergedAt"]) and String.trim(decoded["mergedAt"]) != ""}
        else
          _ -> {:error, :pr_state_lookup_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp merge_now(workspace_path, repo_slug, pr_number) do
    case run_gh(workspace_path, [
           "pr",
           "merge",
           Integer.to_string(pr_number),
           "--repo",
           repo_slug,
           "--squash",
           "--delete-branch"
         ]) do
      {:ok, _} ->
        {:ok, %{auto_merge_enabled: false, pr_merged: true}}

      {:error, {:exit_status, _status, output}} ->
        {:error, {:pr_merge_failed, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp pr_title(%Issue{} = issue), do: "#{issue.identifier}: #{issue.title}"

  defp pr_body(%Issue{} = issue, branch_info, changed?) do
    """
    ## Summary
    Automated review handoff for `#{issue.identifier}`.

    - Issue: #{issue.url || issue.identifier}
    - Branch: `#{branch_info.branch}`
    - Base: `#{branch_info.base_branch}`
    - Changes in this run: #{if(changed?, do: "yes", else: "no new commit")}

    ## Notes
    This PR was created or updated by Symphony as part of the `In Review` handoff.
    """
    |> String.trim()
  end

  defp parse_pr_number(url) when is_binary(url) do
    case Regex.run(~r{/pull/(\d+)}, url, capture: :all_but_first) do
      [value] ->
        case Integer.parse(value) do
          {number, _} -> number
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp repo_slug(workspace_path) do
    with {:ok, remote_url} <- run_git(workspace_path, ["remote", "get-url", "origin"]),
         {:ok, slug} <- parse_repo_slug(remote_url) do
      {:ok, slug}
    end
  end

  defp parse_repo_slug(url) when is_binary(url) do
    normalized =
      url
      |> String.trim()
      |> String.replace_suffix(".git", "")

    cond do
      Regex.match?(~r{^https://github\.com/[^/]+/[^/]+$}, normalized) ->
        [_, owner, repo] = Regex.run(~r{^https://github\.com/([^/]+)/([^/]+)$}, normalized)
        {:ok, "#{owner}/#{repo}"}

      Regex.match?(~r{^git@github\.com:[^/]+/[^/]+$}, normalized) ->
        [_, owner, repo] = Regex.run(~r{^git@github\.com:([^/]+)/([^/]+)$}, normalized)
        {:ok, "#{owner}/#{repo}"}

      true ->
        {:error, {:github_repo_slug_parse_failed, normalized}}
    end
  end

  defp run_git(cwd, args) do
    run_command("git", args, cwd)
  end

  defp run_gh(cwd, args) do
    run_command("gh", args, cwd)
  end

  defp run_command(command, args, cwd) do
    case System.cmd(command, args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, status} ->
        {:error, {:exit_status, status, String.trim(output)}}
    end
  rescue
    error ->
      {:error, {:command_exception, command, Exception.message(error)}}
  end
end
