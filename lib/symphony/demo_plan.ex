defmodule Symphony.DemoPlan do
  @moduledoc "Loads and sanitizes agent-authored demo plans before capture."

  @visible_assertion_types ~w[
    selector_visible
    selector_hidden
    text_present
    text_absent
  ]

  def load_and_sanitize(path) when is_binary(path) do
    with true <- File.exists?(path) || {:error, :demo_plan_missing},
         {:ok, raw} <- File.read(path),
         {:ok, decoded} <- Jason.decode(raw),
         true <- is_map(decoded) || {:error, :demo_plan_invalid} do
      sanitized = sanitize(decoded)

      case write_if_changed(path, raw, sanitized) do
        :ok -> {:ok, sanitized}
        {:error, _reason} = error -> error
      end
    else
      false -> {:error, :demo_plan_missing}
      {:error, _reason} = error -> error
      _ -> {:error, :demo_plan_invalid}
    end
  end

  def sanitize(%{"non_demoable" => true} = plan), do: plan

  def sanitize(plan) when is_map(plan) do
    capture =
      plan
      |> Map.get("capture", "video")
      |> to_string()
      |> String.trim()
      |> String.downcase()

    plan
    |> Map.put("capture", if(capture == "screenshot", do: "screenshot", else: "video"))
    |> Map.put("assertions", sanitize_assertions(capture, Map.get(plan, "assertions")))
  end

  def sanitize(_), do: %{}

  defp sanitize_assertions("screenshot", _assertions), do: []

  defp sanitize_assertions(_capture, assertions) when is_list(assertions) do
    assertions
    |> Enum.filter(&simple_visible_assertion?/1)
    |> Enum.take(2)
  end

  defp sanitize_assertions(_capture, _assertions), do: []

  defp simple_visible_assertion?(%{"type" => type}) when is_binary(type) do
    String.trim(String.downcase(type)) in @visible_assertion_types
  end

  defp simple_visible_assertion?(_), do: false

  defp write_if_changed(path, raw, sanitized) do
    encoded = Jason.encode_to_iodata!(sanitized, pretty: true)

    if IO.iodata_to_binary(encoded) == raw do
      :ok
    else
      File.write(path, [encoded, "\n"])
    end
  end
end
