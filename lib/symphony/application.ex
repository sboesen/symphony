defmodule Symphony.Application do
  @moduledoc false
  use Application

  def start(_type, args) do
    runtime = Symphony.CLI.parse_runtime_args(System.argv())
    _ = Symphony.CLI.apply_runtime_overrides(runtime)

    workflow_path =
      Keyword.get(args, :workflow_path) ||
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
