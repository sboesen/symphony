defmodule Symphony.Application do
  @moduledoc false
  use Application

  def start(_type, args) do
    runtime =
      if Code.ensure_loaded?(Mix) and Mix.env() == :test do
        Symphony.CLI.parse_runtime_args([])
      else
        Symphony.CLI.parse_runtime_args(System.argv())
      end

    _ = Symphony.CLI.apply_runtime_overrides(runtime)

    configured_workflow_path =
      Application.get_env(:symphony, __MODULE__, [])
      |> Keyword.get(:workflow_path)

    workflow_path =
      Keyword.get(args, :workflow_path) ||
        configured_workflow_path ||
        runtime.workflow_path ||
        "./WORKFLOW.md"

    children = [
      {Finch, name: Symphony.Finch},
      {Task.Supervisor, name: Symphony.TaskSupervisor},
      {Symphony.Broker, []},
      {Symphony.Orchestrator, workflow_path: workflow_path},
      {Symphony.GitHubWebhookManager, []}
    ]

    opts = [strategy: :one_for_one, name: Symphony.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
