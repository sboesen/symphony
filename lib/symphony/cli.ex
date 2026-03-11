defmodule Symphony.CLI do
  @moduledoc false

  alias Symphony.Config
  alias Symphony.CLIRuntime
  alias Symphony.GitHubRepo
  alias Symphony.Tracker
  alias Symphony.Workflow
  alias Symphony.WebhookCleanup

  def parse_runtime_args(argv) do
    {opts, args, _} =
      OptionParser.parse(argv,
        strict: [
          help: :boolean,
          workflow: :string,
          project_slug: :string,
          repo: :string,
          linear_api_key: :string,
          port: :integer,
          no_review: :boolean
        ],
        aliases: [h: :help, w: :workflow, p: :port]
      )

    workflow_from_args =
      case args do
        [path | _] -> path
        _ -> nil
      end

    %{
      help?: opts[:help] == true,
      workflow_path: normalize_value(opts[:workflow] || workflow_from_args) || "./WORKFLOW.md",
      project_slug: normalize_value(opts[:project_slug]),
      repo_url: normalize_value(opts[:repo]),
      linear_api_key: normalize_value(opts[:linear_api_key]),
      port: opts[:port],
      no_review?: opts[:no_review] == true
    }
  end

  def apply_runtime_overrides(%{} = parsed) do
    if is_binary(parsed.project_slug), do: System.put_env("LINEAR_PROJECT_SLUG", parsed.project_slug)
    if is_binary(parsed.repo_url) do
      System.put_env("GITHUB_REPO_URL", parsed.repo_url)

      case GitHubRepo.slug_from_ssh(parsed.repo_url) do
        {:ok, slug} -> System.put_env("GITHUB_WEBHOOK_REPO", slug)
        _ -> :ok
      end
    end
    if is_binary(parsed.linear_api_key), do: System.put_env("LINEAR_API_KEY", parsed.linear_api_key)
    if is_integer(parsed.port) and parsed.port > 0, do: System.put_env("SYMPHONY_SERVER_PORT", Integer.to_string(parsed.port))
    if parsed.no_review?, do: System.put_env("SYMPHONY_NO_REVIEW", "true"), else: System.delete_env("SYMPHONY_NO_REVIEW")
    :ok
  end

  def main(argv) do
    parsed = parse_runtime_args(argv)

    if parsed.help? do
      print_help()
      System.halt(0)
    end

    workflow_path = parsed.workflow_path

    unless File.exists?(workflow_path) do
      IO.puts("workflow file not found: #{workflow_path}")
      System.halt(2)
    end

    preflight_runtime_overrides(parsed)
    prestart = ensure_prestart_services()

    parsed =
      case resolve_interactive_defaults(parsed, workflow_path) do
        {:ok, resolved} ->
          resolved

        {:error, reason} ->
          IO.puts("failed to resolve startup defaults: #{inspect(reason)}")
          System.halt(2)
      end

    apply_runtime_overrides(parsed)
    CLIRuntime.persist_runtime_context(parsed, workflow_path)
    lock_file = CLIRuntime.project_lock_path(parsed.project_slug)

    case CLIRuntime.acquire_project_lock(lock_file) do
      :ok ->
        :ok

      {:error, {:already_running, pid}} ->
        IO.puts(
          "another Symphony instance is already running for project #{parsed.project_slug} (pid #{pid})"
        )

        System.halt(1)
    end

    case Process.whereis(Symphony.Supervisor) do
      nil ->
        stop_prestart_services(prestart)

        case Symphony.Application.start(nil, workflow_path: workflow_path) do
          {:ok, _pid} ->
            Process.sleep(:infinity)

          {:error, reason} ->
            CLIRuntime.release_project_lock(lock_file)
            IO.puts("failed to start: #{inspect(reason)}")
            System.halt(1)
        end

      _pid ->
        Process.sleep(:infinity)
    end
  end

  def cleanup_runtime_file(path, workflow_path \\ "./WORKFLOW.md") when is_binary(path) do
    lock_file =
      with true <- File.exists?(path),
           {:ok, body} <- File.read(path),
           {:ok, runtime} <- Jason.decode(body),
           project_slug when is_binary(project_slug) <- normalize_value(runtime["project_slug"]) do
        CLIRuntime.project_lock_path(project_slug)
      else
        _ -> nil
      end

    with true <- File.exists?(path),
         {:ok, body} <- File.read(path),
         {:ok, runtime} <- Jason.decode(body),
         {:ok, workflow} <- Workflow.load(workflow_path),
         {:ok, config} <- Config.from_workflow(workflow) do
      repo_slug =
        runtime["repo_url"]
        |> normalize_value()
        |> case do
          nil -> nil
          repo_url ->
            case GitHubRepo.slug_from_ssh(repo_url) do
              {:ok, slug} -> slug
              _ -> nil
            end
        end

      project_slug = normalize_value(runtime["project_slug"])

      WebhookCleanup.cleanup(config,
        repo_slug: repo_slug,
        project_slug: project_slug
      )
    else
      _ -> :ok
    end

    if is_binary(lock_file), do: CLIRuntime.force_release_project_lock(lock_file)

    :ok
  after
    File.rm(path)
  end

  defp print_help do
    IO.puts("symphony [path-to-WORKFLOW.md] [--workflow PATH] [--project-slug SLUG] [--repo URL] [--port N] [--no-review]")
    IO.puts("")
    IO.puts("Runs the Symphony orchestrator.")
    IO.puts("If project or repo are missing, Symphony will prompt and can persist repo metadata in Linear.")
    IO.puts("")
    IO.puts("Options:")
    IO.puts("  -w, --workflow PATH        Workflow file path (default: ./WORKFLOW.md)")
    IO.puts("      --project-slug SLUG    Override Linear project slug for this run")
    IO.puts("      --repo URL             Override GitHub repo URL for after_create clone hook")
    IO.puts("      --linear-api-key KEY   Override Linear API key for this run")
    IO.puts("  -p, --port N              Override status server port for this run")
    IO.puts("      --no-review           Skip the In Review gate and keep the old auto-merge behavior")
  end

  defp normalize_value(nil), do: nil

  defp normalize_value(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp preflight_runtime_overrides(%{} = parsed) do
    if is_binary(parsed.linear_api_key), do: System.put_env("LINEAR_API_KEY", parsed.linear_api_key)
    if is_integer(parsed.port) and parsed.port > 0, do: System.put_env("SYMPHONY_SERVER_PORT", Integer.to_string(parsed.port))
    if parsed.no_review?, do: System.put_env("SYMPHONY_NO_REVIEW", "true"), else: System.delete_env("SYMPHONY_NO_REVIEW")
    :ok
  end

  defp ensure_prestart_services do
    for app <- [:telemetry, :jason, :yaml_elixir, :finch, :plug_cowboy] do
      {:ok, _} = Application.ensure_all_started(app)
    end

    started_finch_pid =
      case Process.whereis(Symphony.Finch) do
        nil ->
          {:ok, pid} = Finch.start_link(name: Symphony.Finch)
          pid

        _pid ->
          nil
      end

    %{started_finch_pid: started_finch_pid}
  end

  defp stop_prestart_services(%{started_finch_pid: pid}) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.unlink(pid)
      ref = Process.monitor(pid)
      Process.exit(pid, :shutdown)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        1_000 -> :ok
      end
    end

    :ok
  end

  defp stop_prestart_services(_), do: :ok

  defp resolve_interactive_defaults(parsed, workflow_path) do
    with {:ok, workflow} <- Workflow.load(workflow_path),
         {:ok, config} <- Config.from_workflow(workflow) do
      if config.tracker_kind == "linear" do
        project = parsed.project_slug || config.tracker_project_slug
        repo = parsed.repo_url || normalize_value(System.get_env("GITHUB_REPO_URL"))

        with {:ok, project_info, project_slug} <- ensure_project(config, project),
             {:ok, repo_url} <- ensure_repo(config, project_info, repo) do
          {:ok, %{parsed | project_slug: project_slug, repo_url: repo_url}}
        end
      else
        {:ok, parsed}
      end
    end
  end

  defp ensure_project(config, project_slug) when is_binary(project_slug) and project_slug != "" do
    case Tracker.fetch_project_by_slug(config, project_slug) do
      {:ok, nil} -> {:error, :project_not_found}
      {:ok, project} -> {:ok, project, project.slug_id}
      error -> error
    end
  end

  defp ensure_project(config, _missing) do
    with {:ok, projects} <- Tracker.list_projects(config),
         {:ok, project} <- prompt_for_project(projects) do
      {:ok, project, project.slug_id}
    end
  end

  defp ensure_repo(config, project, repo_url) when is_binary(repo_url) and repo_url != "" do
    with {:ok, normalized} <- GitHubRepo.normalize_to_ssh(repo_url),
         {:ok, _slug} <- GitHubRepo.slug_from_ssh(normalized),
         {:ok, _project} <- maybe_persist_repo(config, project, normalized) do
      {:ok, normalized}
    end
  end

  defp ensure_repo(config, project, _missing) do
    case normalize_value(project[:repo_url] || project["repo_url"]) do
      value when is_binary(value) ->
        ensure_repo(config, project, value)

      _ ->
        with {:ok, normalized} <- prompt_for_repo(),
             {:ok, _project} <- maybe_persist_repo(config, project, normalized) do
          {:ok, normalized}
        end
    end
  end

  defp maybe_persist_repo(_config, nil, _repo_url), do: {:ok, nil}

  defp maybe_persist_repo(config, project, repo_url) do
    current = normalize_value(project[:repo_url] || project["repo_url"])

    if current == repo_url do
      {:ok, project}
    else
      Tracker.save_project_repo(config, project, repo_url)
    end
  end

  defp prompt_for_project([]), do: {:error, :no_projects_found}

  defp prompt_for_project(projects) do
    IO.puts("Select a Linear project:")

    projects
    |> Enum.sort_by(&String.downcase(&1.name || ""))
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

      IO.puts("  #{index}. #{project.name}#{suffix} (#{project.slug_id})")
    end)

    sorted = Enum.sort_by(projects, &String.downcase(&1.name || ""))

    case prompt_until_valid("Project number: ", fn input ->
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

  defp prompt_for_repo do
    prompt_until_valid(
      "GitHub repo (https://github.com/org/repo or git@github.com:org/repo.git): ",
      fn input ->
        case GitHubRepo.normalize_to_ssh(input || "") do
          {:ok, normalized} -> {:ok, normalized}
          {:error, _} -> {:error, "Enter a valid GitHub HTTPS or SSH repo URL."}
        end
      end
    )
  end

  defp prompt_until_valid(message, fun) do
    case read_prompt(message) do
      {:ok, input} ->
        case fun.(input) do
          {:ok, value} ->
            {:ok, value}

          {:error, text} when is_binary(text) ->
            IO.puts(text)
            prompt_until_valid(message, fun)

          {:error, reason} ->
            {:error, reason}
        end

      error ->
        error
    end
  end

  defp read_prompt(message) do
    IO.write(message)
    value = IO.gets("")

    case value do
      :eof -> {:error, :interactive_input_required}
      input when is_binary(input) -> {:ok, String.trim(input)}
    end
  end

end
