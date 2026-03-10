defmodule Symphony.PlanContract do
  @moduledoc "Loads, validates, and renders the agent-managed execution plan."

  @rel_path ".git/symphony/plan.json"
  @valid_statuses ~w(pending in_progress completed blocked)
  @workpad_marker "<!-- symphony-workpad -->"
  @workpad_tag "[Symphony:plan]"
  @workpad_footer "_Maintained by Symphony._"
  @max_depth 4

  def path(workspace_path), do: Path.join(workspace_path, @rel_path)
  def workpad_marker, do: @workpad_marker
  def workpad_tag, do: @workpad_tag
  def workpad_footer, do: @workpad_footer

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

  def normalize(%{"steps" => steps} = decoded) when is_list(steps) do
    with {:ok, normalized_steps} <- normalize_steps(steps, 0) do
      {:ok,
       %{
         summary: normalize_text(decoded["summary"]),
         targets: normalize_targets(decoded["targets"]),
         steps: normalized_steps
       }}
    end
  end

  def normalize(_), do: {:error, :invalid}

  def render_workpad(plan) when is_map(plan) do
    heading =
      case normalize_text(plan[:summary] || plan["summary"]) do
        nil -> ["## Plan", ""]
        summary -> ["## Plan", "", summary, ""]
      end

    targets =
      case render_targets(plan[:targets] || plan["targets"]) do
        [] -> []
        lines -> ["Targets:", "" | lines] ++ [""]
      end

    body =
      (plan[:steps] || plan["steps"] || [])
      |> Enum.flat_map(&render_step(&1, 0))

    (heading ++ targets ++ body ++ ["", workpad_tag(), workpad_footer()])
    |> Enum.join("\n")
    |> String.trim()
  end

  def render_planning_placeholder(summary \\ nil) do
    heading = ["## Plan", ""]

    body =
      case normalize_text(summary) do
        nil -> ["Planning in progress..."]
        text -> [text, "", "Planning in progress..."]
      end

    (heading ++ body ++ ["", workpad_tag(), workpad_footer()])
    |> Enum.join("\n")
    |> String.trim()
  end

  def all_done?(plan) when is_map(plan) do
    plan
    |> all_steps()
    |> Enum.all?(fn step -> step[:status] == "completed" end)
  end

  def has_steps?(plan) when is_map(plan) do
    plan
    |> all_steps()
    |> Enum.any?()
  end

  def mark_all_completed(plan) when is_map(plan) do
    Map.update(plan, :steps, plan["steps"] || [], fn steps ->
      Enum.map(steps, &mark_step_completed/1)
    end)
  end

  defp normalize_steps(steps, depth) when depth <= @max_depth do
    steps
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {step, idx}, {:ok, acc} ->
      case normalize_step(step, depth, idx) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_steps(_steps, _depth), do: {:error, :invalid}

  defp normalize_step(%{} = step, depth, idx) do
    content = normalize_text(step["content"] || step["text"] || step[:content] || step[:text])
    status = normalize_status(step["status"] || step[:status])
    id = normalize_text(step["id"] || step[:id]) || default_step_id(depth, idx)
    children = step["children"] || step[:children] || []

    cond do
      is_nil(content) -> {:error, :invalid}
      is_nil(status) -> {:error, :invalid}
      not is_list(children) -> {:error, :invalid}
      true ->
        with {:ok, normalized_children} <- normalize_steps(children, depth + 1) do
          {:ok,
           %{
             id: id,
             content: content,
             status: status,
             children: normalized_children
           }}
        end
    end
  end

  defp normalize_step(_, _depth, _idx), do: {:error, :invalid}

  defp render_step(step, depth) do
    indent = String.duplicate("  ", depth)
    marker = checkbox(step[:status] || step["status"])
    content = step[:content] || step["content"] || ""
    line = "#{indent}- #{marker} #{content}"

    children =
      (step[:children] || step["children"] || [])
      |> Enum.flat_map(&render_step(&1, depth + 1))

    [line | children]
  end

  defp checkbox("completed"), do: "[x]"
  defp checkbox("in_progress"), do: "[-]"
  defp checkbox("blocked"), do: "[!]"
  defp checkbox(_), do: "[ ]"

  defp render_targets(nil), do: []

  defp render_targets(targets) when is_map(targets) do
    routes =
      targets
      |> Map.get(:routes, Map.get(targets, "routes", []))
      |> List.wrap()
      |> Enum.map(&normalize_text/1)
      |> Enum.reject(&is_nil/1)

    files =
      targets
      |> Map.get(:files, Map.get(targets, "files", []))
      |> List.wrap()
      |> Enum.map(&normalize_text/1)
      |> Enum.reject(&is_nil/1)

    surface = normalize_text(Map.get(targets, :surface, Map.get(targets, "surface")))
    artifacts =
      targets
      |> Map.get(:artifacts, Map.get(targets, "artifacts", []))
      |> normalize_string_list()

    []
    |> maybe_render_target_line("Routes", routes)
    |> maybe_render_target_line("Files", files)
    |> maybe_render_target_line("Artifacts", artifacts)
    |> maybe_render_target_line("Surface", surface)
  end

  defp render_targets(_), do: []

  defp maybe_render_target_line(lines, _label, []), do: lines
  defp maybe_render_target_line(lines, _label, nil), do: lines

  defp maybe_render_target_line(lines, label, value) when is_list(value) do
    lines ++ ["- #{label}: #{Enum.join(value, ", ")}"]
  end

  defp maybe_render_target_line(lines, label, value) when is_binary(value) do
    lines ++ ["- #{label}: #{value}"]
  end

  defp all_steps(plan) do
    steps = plan[:steps] || plan["steps"] || []
    flatten_steps(steps, [])
  end

  defp flatten_steps([], acc), do: acc

  defp flatten_steps([step | rest], acc) do
    children = step[:children] || step["children"] || []
    flatten_steps(rest, flatten_steps(children, [step | acc]))
  end

  defp mark_step_completed(step) when is_map(step) do
    children =
      step
      |> Map.get(:children, Map.get(step, "children", []))
      |> Enum.map(&mark_step_completed/1)

    step
    |> Map.put(:status, "completed")
    |> Map.put(:children, children)
    |> Map.delete("status")
    |> Map.delete("children")
  end

  defp normalize_status(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.downcase()

    if normalized in @valid_statuses, do: normalized, else: nil
  end

  defp normalize_status(_), do: nil

  defp normalize_targets(%{} = targets) do
    %{
      routes: normalize_string_list(targets["routes"] || targets[:routes]),
      files: normalize_string_list(targets["files"] || targets[:files]),
      artifacts: normalize_string_list(targets["artifacts"] || targets[:artifacts]),
      surface: normalize_text(targets["surface"] || targets[:surface])
    }
  end

  defp normalize_targets(_), do: %{routes: [], files: [], artifacts: [], surface: nil}

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize_text/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_string_list(_), do: []

  defp normalize_text(nil), do: nil

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.replace(~r/\r\n?/, "\n")
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_text(value), do: value |> to_string() |> normalize_text()

  defp default_step_id(depth, idx), do: "#{depth + 1}.#{idx}"
end
