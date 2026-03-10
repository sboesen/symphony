defmodule Symphony.Issue do
  @moduledoc "Normalized issue model used by orchestration."

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :comments,
    :comments_text,
    :priority,
    :state,
    :branch_name,
    :url,
    :labels,
    :blocked_by,
    :created_at,
    :updated_at,
    feedback_assets: [],
    feedback_assets_text: ""
  ]

  def from_payload(payload, opts \\ []) when is_map(payload) do
    comments = extract_comments(payload, opts)

    %__MODULE__{
      id: payload["id"],
      identifier: payload["identifier"],
      title: payload["title"],
      description: payload["description"],
      comments: comments,
      comments_text: format_comments_text(comments),
      priority: parse_int(payload["priority"]),
      state: normalize_state(extract_state(payload)),
      branch_name: payload["branchName"] || payload[:branchName] || payload["branch_name"],
      url: payload["url"],
      labels: extract_labels(payload),
      blocked_by: extract_blockers(payload),
      created_at:
        parse_time(payload["createdAt"] || payload[:createdAt] || payload["created_at"]),
      updated_at: parse_time(payload["updatedAt"] || payload[:updatedAt] || payload["updated_at"])
    }
  end

  def normalize_state(nil), do: nil
  def normalize_state(value) when is_binary(value), do: String.trim(String.downcase(value))
  def normalize_state(%{"name" => value}), do: normalize_state(value)
  def normalize_state(%{name: value}), do: normalize_state(value)
  def normalize_state(_), do: nil

  def blocked_by_has_non_terminal?(%__MODULE__{blocked_by: blockers}, terminal_states) do
    Enum.any?(blockers || [], fn blocker ->
      case normalize_state(blocker[:state] || blocker["state"]) do
        nil -> false
        state -> state not in terminal_states
      end
    end)
  end

  defp extract_state(payload) do
    case payload["state"] do
      state when is_binary(state) -> state
      %{"name" => name} -> name
      %{name: name} -> name
      _ -> nil
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(v) when is_integer(v), do: v

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  defp parse_time(nil), do: nil

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_time(_), do: nil

  defp extract_labels(payload) do
    payload
    |> get_in_flexible(["labels", "nodes"], [[:labels, :nodes]])
    |> Enum.map(fn item ->
      (item["name"] || item[:name] || "")
      |> String.downcase()
    end)
    |> Enum.filter(&(&1 != ""))
    |> Enum.uniq()
  end

  defp extract_blockers(payload) do
    payload
    |> get_in_flexible(["blockedBy", "nodes"], [[:blockedBy, :nodes], [:blocked_by, :nodes]])
    |> Enum.map(fn node ->
      %{
        id: node["id"] || node[:id],
        identifier: node["identifier"] || node[:identifier],
        state: extract_state(node)
      }
    end)
  end

  defp extract_comments(payload, opts) do
    include_managed_comments? = Keyword.get(opts, :include_managed_comments, false)

    payload
    |> get_in_flexible(["comments", "nodes"], [[:comments, :nodes]])
    |> Enum.map(&comment_from_payload/1)
    |> Enum.filter(fn comment ->
      comment.body != "" and
        (include_managed_comments? or not symphony_managed_comment?(comment.body))
    end)
    |> Enum.sort_by(
      fn comment ->
        if comment.created_at, do: DateTime.to_unix(comment.created_at, :microsecond), else: 0
      end,
      :desc
    )
    |> Enum.take(8)
  end

  defp comment_from_payload(node) do
    %{
      id: node["id"] || node[:id],
      body: normalize_comment_body(node["body"] || node[:body]),
      user_name:
        get_in(node, ["user", "name"]) || get_in(node, [:user, :name]) ||
          node["userName"] || node[:userName],
      created_at: parse_time(node["createdAt"] || node[:createdAt] || node["created_at"]),
      updated_at: parse_time(node["updatedAt"] || node[:updatedAt] || node["updated_at"])
    }
  end

  defp format_comments_text([]), do: ""

  defp format_comments_text(comments) do
    comments
    |> Enum.reverse()
    |> Enum.map(fn comment ->
      author = comment.user_name || "Unknown"

      timestamp =
        if comment.created_at, do: DateTime.to_iso8601(comment.created_at), else: "unknown-time"

      "- [#{timestamp}] #{author}: #{comment.body}"
    end)
    |> Enum.join("\n")
  end

  defp normalize_comment_body(nil), do: ""

  defp normalize_comment_body(value) when is_binary(value) do
    value
    |> String.replace(~r/\r\n?/, "\n")
    |> String.trim()
  end

  defp normalize_comment_body(_), do: ""

  def symphony_managed_comment?(body) when is_binary(body) do
    String.contains?(body, "[Symphony:plan]") or
      String.contains?(body, "[Symphony:review]") or
      String.contains?(body, "[Symphony:recording]") or
      String.contains?(body, "<!-- symphony-clarification -->") or
      String.contains?(body, "<!-- symphony-review -->") or
      String.contains?(body, "<!-- symphony-recording -->") or
      String.contains?(body, "_Maintained by Symphony._") or
      String.contains?(body, "<!-- symphony-workpad -->") or
      String.contains?(body, "_Symphony review handoff._") or
      String.contains?(body, "_Symphony recording artifact._")
  end

  def symphony_managed_comment?(_), do: false

  defp get_in_flexible(payload, string_path, atom_paths) do
    value =
      get_path(payload, string_path) ||
        Enum.find_value(atom_paths, fn path -> get_path(payload, path) end)

    if is_list(value), do: value, else: []
  end

  defp get_path(value, []), do: value

  defp get_path(%{} = value, [key | rest]) do
    case Map.fetch(value, key) do
      {:ok, next} -> get_path(next, rest)
      :error -> nil
    end
  end

  defp get_path(_, _path), do: nil
end
