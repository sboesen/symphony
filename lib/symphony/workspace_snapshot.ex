defmodule Symphony.WorkspaceSnapshot do
  @moduledoc "Captures lightweight git workspace state for progress detection between turns."

  def capture(workspace_path) when is_binary(workspace_path) do
    %{
      head: git_output(workspace_path, ["rev-parse", "HEAD"]),
      status: git_output(workspace_path, ["status", "--short", "--untracked-files=all"]),
      demo_plan_exists?: File.exists?(Path.join(workspace_path, ".git/symphony/demo-plan.json"))
    }
  end

  def progress_made?(workspace_path, snapshot) when is_binary(workspace_path) and is_map(snapshot) do
    current = capture(workspace_path)

    current.head != snapshot.head or
      current.status != snapshot.status or
      current.demo_plan_exists? != snapshot.demo_plan_exists?
  end

  def progress_made?(_workspace_path, _snapshot), do: false

  defp git_output(workspace_path, args) do
    case System.cmd("git", args, cd: workspace_path, stderr_to_stdout: true) do
      {out, 0} -> out
      _ -> nil
    end
  end
end
