defmodule Symphony.CLI do
  @moduledoc false

  def parse_runtime_args(argv) do
    {opts, args, _} =
      OptionParser.parse(argv,
        strict: [
          help: :boolean,
          workflow: :string,
          project_slug: :string,
          repo: :string,
          linear_api_key: :string,
          port: :integer
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
      port: opts[:port]
    }
  end

  def apply_runtime_overrides(%{} = parsed) do
    if is_binary(parsed.project_slug), do: System.put_env("LINEAR_PROJECT_SLUG", parsed.project_slug)
    if is_binary(parsed.repo_url), do: System.put_env("GITHUB_REPO_URL", parsed.repo_url)
    if is_binary(parsed.linear_api_key), do: System.put_env("LINEAR_API_KEY", parsed.linear_api_key)
    if is_integer(parsed.port) and parsed.port > 0, do: System.put_env("SYMPHONY_SERVER_PORT", Integer.to_string(parsed.port))
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

    apply_runtime_overrides(parsed)

    case Symphony.Application.start(nil, workflow_path: workflow_path) do
      {:ok, _pid} ->
        Process.sleep(:infinity)

      {:error, reason} ->
        IO.puts("failed to start: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp print_help do
    IO.puts("symphony [path-to-WORKFLOW.md] [--workflow PATH] [--project-slug SLUG] [--repo URL] [--port N]")
    IO.puts("")
    IO.puts("Runs the Symphony orchestrator.")
    IO.puts("")
    IO.puts("Options:")
    IO.puts("  -w, --workflow PATH        Workflow file path (default: ./WORKFLOW.md)")
    IO.puts("      --project-slug SLUG    Override Linear project slug for this run")
    IO.puts("      --repo URL             Override GitHub repo URL for after_create clone hook")
    IO.puts("      --linear-api-key KEY   Override Linear API key for this run")
    IO.puts("  -p, --port N              Override status server port for this run")
  end

  defp normalize_value(nil), do: nil

  defp normalize_value(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end
end
