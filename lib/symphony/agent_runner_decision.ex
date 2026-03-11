defmodule Symphony.AgentRunnerDecision do
  @moduledoc "Pure decision helpers for AgentRunner turn flow and timeout salvage."

  alias Symphony.Issue

  def next_turn_action(%{status: "completed"}, opts) when is_map(opts) do
    case opts[:plan_ready] do
      :ok -> :stop
      {:error, reason} -> {:error, reason}
    end
  end

  def next_turn_action(%{status: "blocked"} = completion, _opts) do
    {:error, {:blocked, completion}}
  end

  def next_turn_action(%{status: "needs_more_work"} = completion, opts) when is_map(opts) do
    cond do
      opts[:turn_index] >= opts[:max_turns] ->
        {:error, {:max_turns_exceeded, completion}}

      not active_state?(opts[:issue_state], opts[:active_states] || []) ->
        {:error, {:needs_more_work_but_issue_not_active, completion}}

      opts[:progress_made?] ->
        :continue

      true ->
        {:error, {:needs_more_work_without_progress, completion}}
    end
  end

  def salvage_timeout_result(reason, completion_result, demo_plan_exists?, branch_has_committed_changes?) do
    if reason in [:stall_timeout, :turn_timeout] do
      case completion_result do
        {:ok, completion} ->
          {:ok, %{status: completion.status, completion: completion}}

        {:error, :missing} ->
          if demo_plan_exists? or branch_has_committed_changes? do
            {:ok, %{status: "completed", completion: nil, salvaged: true}}
          else
            :no_salvage
          end

        _ ->
          :no_salvage
      end
    else
      :no_salvage
    end
  end

  defp active_state?(state, active_states) do
    Issue.normalize_state(state) in active_states
  end
end
