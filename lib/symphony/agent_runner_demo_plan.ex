defmodule Symphony.AgentRunnerDemoPlan do
  @moduledoc false

  def validate_file(path) when is_binary(path) do
    with {:ok, decoded} <- Symphony.DemoPlan.load_and_sanitize(path),
         :ok <- validate_map(decoded) do
      :ok
    else
      {:error, _reason} = error -> error
      _ -> {:error, :demo_plan_invalid}
    end
  end

  def validate_map(%{"non_demoable" => true}), do: :ok

  def validate_map(plan) when is_map(plan) do
    plan =
      case Map.get(plan, "capture") do
        "screenshot" -> Map.put(plan, "assertions", [])
        _ -> plan
      end

    ready_url = plan_string(plan, "ready_url")
    url = plan_string(plan, "url")
    setup_command = plan_string(plan, "setup_command")
    effective_url = ready_url || url || ""

    case URI.parse(effective_url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and host in ["127.0.0.1", "localhost", "::1"] ->
        if is_binary(setup_command) and String.trim(setup_command) != "" do
          :ok
        else
          {:error, :recording_setup_command_missing}
        end

      _ ->
        :ok
    end
  end

  def validate_map(_), do: {:error, :demo_plan_invalid}

  def plan_string(plan, key) when is_map(plan) do
    case Map.get(plan, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end
end
