defmodule Symphony.CompletionResult do
  @moduledoc "Loads and validates the agent-written completion contract for a turn."

  @rel_path ".git/symphony/result.json"
  @valid_statuses ~w(completed needs_more_work blocked)

  def path(workspace_path), do: Path.join(workspace_path, @rel_path)

  def load(workspace_path) when is_binary(workspace_path) do
    file_path = path(workspace_path)

    with true <- File.exists?(file_path) or {:error, :missing},
         {:ok, raw} <- File.read(file_path),
         {:ok, decoded} <- Jason.decode(raw),
         {:ok, normalized} <- normalize(decoded) do
      {:ok, normalized}
    else
      false -> {:error, :missing}
      {:error, _} = error -> error
      _ -> {:error, :invalid}
    end
  end

  def completed?(%{status: "completed"}), do: true
  def completed?(_), do: false

  defp normalize(%{"status" => status} = decoded) when status in @valid_statuses do
    {:ok,
     %{
       status: status,
       summary: normalize_text(decoded["summary"]),
       tests: normalize_string_list(decoded["tests"]),
       artifacts: normalize_string_list(decoded["artifacts"]),
       notes: normalize_text(decoded["notes"])
     }}
  end

  defp normalize(_), do: {:error, :invalid}

  defp normalize_text(nil), do: nil

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_text(value), do: to_string(value)

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize_text/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_string_list(_), do: []
end
