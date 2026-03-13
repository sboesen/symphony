defmodule Symphony.CLIInteractive do
  @moduledoc false

  alias Symphony.GitHubRepo
  alias Symphony.Tracker

  def resolve_defaults(parsed, config, opts \\ []) do
    deps = deps(opts)

    if config.tracker_kind == "linear" do
      project = parsed.project_slug || config.tracker_project_slug
      repo = parsed.repo_url || normalize_value(deps.env_get.("GITHUB_REPO_URL"))

      with {:ok, project_info, project_slug} <- ensure_project(config, project, deps),
           {:ok, repo_url} <- ensure_repo(config, project_info, repo, deps) do
        {:ok, %{parsed | project_slug: project_slug, repo_url: repo_url}}
      end
    else
      {:ok, parsed}
    end
  end

  def ensure_project(config, project_slug, opts \\ [])

  def ensure_project(config, project_slug, %{tracker_fetch_project_by_slug: fetch_fun})
      when is_binary(project_slug) and project_slug != "" do
    case fetch_fun.(config, project_slug) do
      {:ok, nil} -> {:error, :project_not_found}
      {:ok, project} -> {:ok, project, project.slug_id}
      error -> error
    end
  end

  def ensure_project(config, _missing, opts) do
    deps = deps(opts)

    with {:ok, projects} <- deps.tracker_list_projects.(config),
         {:ok, project} <- prompt_for_project(projects, deps) do
      {:ok, project, project.slug_id}
    end
  end

  def ensure_repo(config, project, repo_url, opts \\ [])

  def ensure_repo(config, project, repo_url, opts)
      when is_binary(repo_url) and repo_url != "" do
    deps = deps(opts)

    with {:ok, normalized} <- deps.github_normalize_to_ssh.(repo_url),
         {:ok, _slug} <- deps.github_slug_from_ssh.(normalized),
         {:ok, _project} <- maybe_persist_repo(config, project, normalized, deps) do
      {:ok, normalized}
    end
  end

  def ensure_repo(config, project, _missing, opts) do
    deps = deps(opts)

    case normalize_value(project[:repo_url] || project["repo_url"]) do
      value when is_binary(value) ->
        ensure_repo(config, project, value, deps)

      _ ->
        with {:ok, normalized} <- prompt_for_repo(deps),
             {:ok, _project} <- maybe_persist_repo(config, project, normalized, deps) do
          {:ok, normalized}
        end
    end
  end

  def maybe_persist_repo(_config, nil, _repo_url, _opts), do: {:ok, nil}

  def maybe_persist_repo(config, project, repo_url, opts) do
    deps = deps(opts)
    current = normalize_value(project[:repo_url] || project["repo_url"])

    if current == repo_url do
      {:ok, project}
    else
      deps.tracker_save_project_repo.(config, project, repo_url)
    end
  end

  def prompt_for_project([], _opts), do: {:error, :no_projects_found}

  def prompt_for_project(projects, opts) do
    deps = deps(opts)
    deps.puts.("Select a Linear project:")

    sorted =
      Enum.sort_by(projects, fn project ->
        String.downcase(project.name || "")
      end)

    sorted
    |> Enum.with_index(1)
    |> Enum.each(fn {project, index} ->
      teams =
        project
        |> Map.get(:team_keys, [])
        |> Enum.join(", ")

      suffix =
        case teams do
          "" -> ""
          value -> " [#{value}]"
        end

      deps.puts.("  #{index}. #{project.name}#{suffix} (#{project.slug_id})")
    end)

    case prompt_until_valid("Project number: ", deps, fn input ->
           case Integer.parse(input || "") do
             {value, ""} when value >= 1 and value <= length(sorted) ->
               {:ok, Enum.at(sorted, value - 1)}

             _ ->
               {:error, "Enter a number between 1 and #{length(sorted)}."}
           end
         end) do
      {:ok, project} -> {:ok, project}
      error -> error
    end
  end

  def prompt_for_repo(opts \\ []) do
    deps = deps(opts)

    prompt_until_valid(
      "GitHub repo (https://github.com/org/repo or git@github.com:org/repo.git): ",
      deps,
      fn input ->
        case deps.github_normalize_to_ssh.(input || "") do
          {:ok, normalized} -> {:ok, normalized}
          {:error, _} -> {:error, "Enter a valid GitHub HTTPS or SSH repo URL."}
        end
      end
    )
  end

  def prompt_until_valid(message, opts, fun) when is_function(fun, 1) do
    deps = deps(opts)

    case deps.read_prompt.(message) do
      {:ok, input} ->
        case fun.(input) do
          {:ok, value} ->
            {:ok, value}

          {:error, text} when is_binary(text) ->
            deps.puts.(text)
            prompt_until_valid(message, deps, fun)

          {:error, reason} ->
            {:error, reason}
        end

      error ->
        error
    end
  end

  def read_prompt(message, opts \\ []) do
    deps = deps(opts)
    deps.write.(message)
    value = deps.gets.("")

    case value do
      :eof -> {:error, :interactive_input_required}
      input when is_binary(input) -> {:ok, String.trim(input)}
    end
  end

  def normalize_value(nil), do: nil

  def normalize_value(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp deps(opts) do
    map = if is_map(opts), do: opts, else: Enum.into(opts, %{})

    Map.merge(
      %{
        env_get: &System.get_env/1,
        tracker_fetch_project_by_slug: &Tracker.fetch_project_by_slug/2,
        tracker_list_projects: &Tracker.list_projects/1,
        tracker_save_project_repo: &Tracker.save_project_repo/3,
        github_normalize_to_ssh: &GitHubRepo.normalize_to_ssh/1,
        github_slug_from_ssh: &GitHubRepo.slug_from_ssh/1,
        puts: &IO.puts/1,
        write: &IO.write/1,
        gets: &IO.gets/1,
        read_prompt: &read_prompt/1
      },
      map
    )
  end
end
