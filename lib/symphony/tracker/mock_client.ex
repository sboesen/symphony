defmodule Symphony.Tracker.MockClient do
  @moduledoc "Local JSON tracker client used for development and testing."

  alias Symphony.Issue

  def fetch_candidates(config) do
    fetch_by_states(config, config.tracker_active_states)
  end

  def fetch_states_by_ids(_config, []), do: {:ok, []}

  def fetch_states_by_ids(config, issue_ids) when is_list(issue_ids) do
    wanted_ids =
      issue_ids
      |> Enum.map(&normalize_id/1)
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    with {:ok, issues} <- load_issues(config) do
      filtered =
        Enum.filter(issues, fn issue ->
          normalize_id(issue.id) in wanted_ids
        end)

      {:ok, filtered}
    end
  end

  def fetch_terminal_issues(config, terminal_states) do
    fetch_by_states(config, terminal_states)
  end

  def mark_started(_config, _issue_id), do: :ok
  def mark_completed(_config, _issue_id), do: :ok

  defp fetch_by_states(config, states) do
    wanted_states = normalize_state_set(states)

    if MapSet.size(wanted_states) == 0 do
      {:ok, []}
    else
      with {:ok, issues} <- load_issues(config) do
        filtered =
          Enum.filter(issues, fn issue ->
            Issue.normalize_state(issue.state) in wanted_states
          end)

        {:ok, filtered}
      end
    end
  end

  defp load_issues(config) do
    path = resolve_mock_path(config)

    with {:ok, raw} <- File.read(path),
         {:ok, decoded} <- Jason.decode(raw),
         {:ok, entries} <- extract_entries(decoded) do
      entries
      |> Enum.filter(&is_map/1)
      |> Enum.map(&Issue.from_payload/1)
      |> then(&{:ok, &1})
    else
      {:error, :enoent} ->
        {:error, {:mock_file_not_found, path}}

      {:error, reason} when reason in [:eacces, :eisdir, :enotdir] ->
        {:error, {:mock_file_read_error, reason}}

      {:error, _} ->
        {:error, :mock_file_malformed}

      _ ->
        {:error, :mock_file_malformed}
    end
  end

  defp extract_entries(list) when is_list(list), do: {:ok, list}

  defp extract_entries(%{} = map) do
    entries =
      map["issues"] || map[:issues] ||
        get_in(map, ["data", "issues"]) ||
        get_in(map, [:data, :issues]) ||
        map["nodes"] || map[:nodes] || []

    if is_list(entries) do
      {:ok, entries}
    else
      {:error, :invalid_mock_shape}
    end
  end

  defp extract_entries(_), do: {:error, :invalid_mock_shape}

  defp normalize_state_set(states) do
    states
    |> List.wrap()
    |> Enum.map(&Issue.normalize_state/1)
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  defp normalize_id(nil), do: nil
  defp normalize_id(value) when is_binary(value), do: String.trim(value)
  defp normalize_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_id(_), do: nil

  defp resolve_mock_path(config) do
    path = config.tracker_mock_file || ""

    if Path.type(path) == :absolute do
      path
    else
      Path.expand(path, File.cwd!())
    end
  end
end
