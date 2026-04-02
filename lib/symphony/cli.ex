defmodule Symphony.CLI do
  @moduledoc false

  alias Symphony.Config
  alias Symphony.CLICommand
  alias Symphony.CLIInteractive
  alias Symphony.CLIRuntime
  alias Symphony.GitHubRepo
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
    case CLICommand.run(parse_runtime_args(argv), CLICommand.deps()) do
      {:halt, 0, :help} ->
        print_help()
        System.halt(0)

      {:halt, code, message} when is_binary(message) ->
        IO.puts(message)
        System.halt(code)

      {:sleep_forever, _parsed} ->
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

  def preflight_runtime_overrides(%{} = parsed) do
    if is_binary(parsed.linear_api_key), do: System.put_env("LINEAR_API_KEY", parsed.linear_api_key)
    if is_integer(parsed.port) and parsed.port > 0, do: System.put_env("SYMPHONY_SERVER_PORT", Integer.to_string(parsed.port))
    if parsed.no_review?, do: System.put_env("SYMPHONY_NO_REVIEW", "true"), else: System.delete_env("SYMPHONY_NO_REVIEW")
    :ok
  end

  def ensure_prestart_services do
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

  def stop_prestart_services(%{started_finch_pid: pid}) when is_pid(pid) do
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

  def stop_prestart_services(_), do: :ok

  def resolve_interactive_defaults(parsed, workflow_path) do
    with {:ok, workflow} <- Workflow.load(workflow_path),
         {:ok, config} <- Config.from_workflow(workflow) do
      CLIInteractive.resolve_defaults(parsed, config)
    end
  end

end
