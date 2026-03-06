defmodule Symphony.TemplateRenderer do
  @moduledoc "Strict template rendering with unknown-variable/filter rejection."

  @token_re ~r/{{\s*([^}]+?)\s*}}/

  def render(template, issue, attempt) when is_binary(template) do
    body = if String.trim(template) == "", do: "You are working on an issue from Linear.", else: template

    result =
      Regex.replace(@token_re, body, fn full, expr ->
        case render_expression(String.trim(expr), issue, attempt) do
          {:ok, replacement} -> replacement
          {:error, _} -> "#{full}"
        end
      end)

    if String.contains?(result, "{{") do
      {:error, :template_render_error}
    else
      {:ok, result}
    end
  end

  defp render_expression("attempt", _issue, attempt), do: {:ok, format_value(attempt)}

  defp render_expression("issue", issue, _attempt) do
    {:ok, format_value(Map.from_struct(issue))}
  end

  defp render_expression(expression, issue, _attempt) do
    if String.contains?(expression, "|") do
      {:error, :unknown_filter}
    else
      parts = String.split(expression, ".", trim: true)
      if parts == [] or hd(parts) != "issue" do
        {:error, :unknown_variable}
      else
        issue_map = map_as_string_keys(Map.from_struct(issue))

        value =
          Enum.reduce_while(Enum.drop(parts, 1), issue_map, fn part, acc ->
            cond do
              is_map(acc) and Map.has_key?(acc, part) ->
                {:cont, Map.get(acc, part)}

              true ->
                {:halt, :missing}
            end
          end)

        if value == :missing do
          {:error, :unknown_variable}
        else
          {:ok, format_value(value)}
        end
      end
    end
  end

  defp map_as_string_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp format_value(nil), do: ""
  defp format_value(v) when is_binary(v), do: v
  defp format_value(v) when is_integer(v), do: Integer.to_string(v)
  defp format_value(v) when is_list(v), do: Jason.encode!(v)
  defp format_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_value(v), do: inspect(v)
end
