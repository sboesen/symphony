defmodule Symphony.GitHubRepo do
  @moduledoc "Helpers for normalizing GitHub repository URLs."

  def normalize_to_ssh(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:error, :repo_missing}

      Regex.match?(~r/^git@github\.com:[^[:space:]]+?(\.git)?$/, trimmed) ->
        {:ok, ensure_git_suffix(trimmed)}

      Regex.match?(~r/^https:\/\/github\.com\/[^\/]+\/[^\/]+?(\.git)?\/?$/, trimmed) ->
        [_, owner, repo] = Regex.run(~r/^https:\/\/github\.com\/([^\/]+)\/([^\/]+?)(?:\.git)?\/?$/, trimmed)
        {:ok, "git@github.com:#{owner}/#{repo}.git"}

      true ->
        {:error, :invalid_repo_url}
    end
  end

  def normalize_to_ssh(_), do: {:error, :invalid_repo_url}

  def slug_from_ssh(value) when is_binary(value) do
    case normalize_to_ssh(value) do
      {:ok, normalized} ->
        case Regex.run(~r/^git@github\.com:([^\/]+)\/(.+)\.git$/, normalized) do
          [_, owner, repo] -> {:ok, "#{owner}/#{repo}"}
          _ -> {:error, :invalid_repo_url}
        end

      error ->
        error
    end
  end

  def slug_from_ssh(_), do: {:error, :invalid_repo_url}

  defp ensure_git_suffix(value) do
    if String.ends_with?(value, ".git"), do: value, else: value <> ".git"
  end
end
