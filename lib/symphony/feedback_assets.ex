defmodule Symphony.FeedbackAssets do
  @moduledoc "Downloads image feedback from Linear issue descriptions/comments into the workspace."

  alias Symphony.Issue

  @linear_upload_re ~r{https://uploads\.linear\.app/[^\s<>)\]]+}

  def sync(%Issue{} = issue, config, workspace_path) when is_binary(workspace_path) do
    references = extract_references(issue)

    assets =
      references
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {reference, index} ->
        case ensure_asset(reference, index, config, workspace_path) do
          {:ok, asset} -> [asset]
          _ -> []
        end
      end)

    %Issue{issue | feedback_assets: assets, feedback_assets_text: format_assets_text(assets, workspace_path)}
  end

  def sync(%Issue{} = issue, _config, _workspace_path), do: issue

  def extract_references(%Issue{} = issue) do
    description_refs =
      extract_urls(issue.description || "")
      |> Enum.map(fn url ->
        %{
          url: url,
          source: "description",
          excerpt: excerpt(issue.description || "")
        }
      end)

    comment_refs =
      issue.comments
      |> List.wrap()
      |> Enum.flat_map(fn comment ->
        extract_urls(comment.body || "")
        |> Enum.map(fn url ->
          %{
            url: url,
            source: "comment",
            excerpt: excerpt(comment.body || "")
          }
        end)
      end)

    (description_refs ++ comment_refs)
    |> Enum.uniq_by(& &1.url)
  end

  defp extract_urls(text) when is_binary(text) do
    @linear_upload_re
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.map(&String.trim_trailing(&1, ".,"))
  end

  defp excerpt(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 120)
  end

  defp ensure_asset(reference, index, config, workspace_path) do
    with api_key when is_binary(api_key) and api_key != "" <- config.tracker_api_key,
         {:ok, body, content_type} <- download(reference.url, api_key),
         {:ok, ext} <- extension_for_content_type(content_type) do
      dir = Path.join(workspace_path, ".git/symphony/feedback")
      File.mkdir_p!(dir)

      digest =
        :crypto.hash(:sha256, reference.url)
        |> Base.encode16(case: :lower)
        |> binary_part(0, 12)

      filename = "feedback-#{index}-#{digest}#{ext}"
      path = Path.join(dir, filename)
      File.write!(path, body)

      {:ok,
       %{
         path: path,
         relative_path: Path.relative_to(path, workspace_path),
         url: reference.url,
         source: reference.source,
         excerpt: reference.excerpt
       }}
    else
      _ -> {:error, :download_failed}
    end
  end

  defp download(url, api_key) do
    request =
      Finch.build(:get, url, [
        {"authorization", api_key},
        {"user-agent", "symphony"}
      ])

    case Finch.request(request, Symphony.Finch) do
      {:ok, %Finch.Response{status: 200, headers: response_headers, body: body}} ->
        content_type =
          response_headers
          |> Enum.find_value(fn
            {key, value} when is_binary(key) ->
              if String.downcase(key) == "content-type", do: value, else: nil
            _ -> nil
          end)

        {:ok, body, content_type || "application/octet-stream"}

      _ ->
        {:error, :http_failed}
    end
  end

  defp extension_for_content_type(content_type) when is_binary(content_type) do
    normalized = String.downcase(String.trim(content_type))

    cond do
      String.starts_with?(normalized, "image/png") -> {:ok, ".png"}
      String.starts_with?(normalized, "image/jpeg") -> {:ok, ".jpg"}
      String.starts_with?(normalized, "image/webp") -> {:ok, ".webp"}
      String.starts_with?(normalized, "image/gif") -> {:ok, ".gif"}
      true -> {:error, :unsupported_content_type}
    end
  end

  defp format_assets_text([], _workspace_path), do: ""

  defp format_assets_text(assets, _workspace_path) do
    lines =
      assets
      |> Enum.map(fn asset ->
        source =
          case asset.source do
            "description" -> "description"
            "comment" -> "comment"
            other -> other
          end

        "- #{asset.relative_path} (from #{source}: #{inspect(asset.excerpt)})"
      end)

    """
    Screenshot feedback files downloaded into the workspace:
    #{Enum.join(lines, "\n")}

    Use these local image files as review context if helpful.
    """
    |> String.trim()
  end
end
