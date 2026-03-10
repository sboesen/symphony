defmodule Symphony.ProjectMetadata do
  @moduledoc "Stores Symphony config in Linear project descriptions."

  @repo_prefix "Repo:"
  @repo_line_regex ~r/^(?<prefix>\s*Repo:\s*)(?<value>.+?)\s*$/mi
  @marker_start "<!-- symphony-project-config"
  @marker_regex ~r/<!--\s*symphony-project-config\s+(\{.*?\})\s*-->/s

  def parse(description) when is_binary(description) do
    repo_url =
      parse_repo_line(description) ||
        parse_hidden_marker(description)

    %{repo_url: repo_url, raw: %{}}
  end

  def parse(_), do: %{repo_url: nil, raw: %{}}

  def upsert_repo(description, repo_url) when is_binary(repo_url) do
    base =
      (description || "")
      |> remove_hidden_marker()
      |> upsert_repo_line(repo_url)

    base
    |> String.trim_trailing()
  end

  def marker_start, do: @marker_start
  def repo_prefix, do: @repo_prefix

  defp parse_repo_line(description) when is_binary(description) do
    case Regex.named_captures(@repo_line_regex, description) do
      %{"value" => value} -> normalize_text(value)
      _ -> nil
    end
  end

  defp parse_hidden_marker(description) when is_binary(description) do
    case Regex.run(@marker_regex, description, capture: :all_but_first) do
      [json] ->
        with {:ok, decoded} <- Jason.decode(json),
             true <- is_map(decoded) do
          normalize_text(decoded["repo_url"] || decoded["repoUrl"])
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp upsert_repo_line(description, repo_url) do
    repo_line = "#{@repo_prefix} #{repo_url}"

    cond do
      Regex.match?(@repo_line_regex, description) ->
        Regex.replace(@repo_line_regex, description, repo_line, global: false)

      String.trim(description) == "" ->
        repo_line

      true ->
        String.trim_trailing(description) <> "\n\n" <> repo_line
    end
  end

  defp remove_hidden_marker(description) do
    Regex.replace(@marker_regex, description, "")
  end

  defp normalize_text(nil), do: nil

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_text(value), do: value |> to_string() |> normalize_text()
end
