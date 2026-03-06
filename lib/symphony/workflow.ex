defmodule Symphony.Workflow do
  @moduledoc "Loads `WORKFLOW.md` and separates YAML front matter from prompt body."

  defstruct [:path, :config, :prompt_template, :mtime_ms]

  def load(path) do
    with {:ok, stat} <- File.stat(path),
         {:ok, content} <- File.read(path),
         {:ok, parsed} <- parse_content(content) do
      mtime_ms =
        case stat.mtime do
          {{y, m, d}, {h, min, s}} ->
            NaiveDateTime.from_erl!({{y, m, d}, {h, min, s}})
            |> DateTime.from_naive!("Etc/UTC")
            |> DateTime.to_unix(:millisecond)

          _ ->
            System.system_time(:millisecond)
        end

      {:ok,
       %__MODULE__{
         path: path,
         config: parsed.config,
         prompt_template: parsed.prompt_template,
         mtime_ms: mtime_ms
       }}
    else
      {:error, :enoent} -> {:error, :missing_workflow_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_content(content) do
    if String.starts_with?(content, "---") do
      case Regex.run(~r/\A---\R(.*?)\R---\R?(.*)\z/s, content, capture: :all_but_first) do
        [front_matter, prompt] ->
          with {:ok, decoded} <- YamlElixir.read_from_string(front_matter) do
            if is_map(decoded) do
              {:ok, %{config: decoded, prompt_template: String.trim(prompt)}}
            else
              {:error, :workflow_front_matter_not_a_map}
            end
          else
            _ -> {:error, :workflow_parse_error}
          end

        _ ->
          {:error, :workflow_parse_error}
      end
    else
      {:ok, %{config: %{}, prompt_template: String.trim(content)}}
    end
  end
end
