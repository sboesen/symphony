defmodule Symphony.AgentRunnerDemoContext do
  @moduledoc false

  def prompt(workspace_path) do
    case detect(workspace_path) do
      nil ->
        "Repo demo context: none detected. Inspect the workspace before choosing any local demo setup."

      context ->
        [
          "Repo demo context:",
          maybe_context_line("Detected framework", context[:framework]),
          maybe_context_line("Likely package manager", context[:package_manager]),
          maybe_context_line("Detected dev script", context[:dev_script]),
          maybe_context_line("Suggested local demo command", context[:suggested_setup_command]),
          maybe_context_line("Suggested local demo URL", context[:suggested_url]),
          maybe_context_line("Note", context[:note])
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")
    end
  end

  def detect(workspace_path) do
    package_json_path = Path.join(workspace_path, "package.json")

    with true <- File.exists?(package_json_path),
         {:ok, raw} <- File.read(package_json_path),
         {:ok, decoded} <- Jason.decode(raw),
         true <- is_map(decoded) do
      build_context(workspace_path, decoded)
    else
      _ -> nil
    end
  end

  def build_context(workspace_path, package_json) when is_map(package_json) do
    scripts = Map.get(package_json, "scripts", %{})
    deps = Map.get(package_json, "dependencies", %{})
    dev_deps = Map.get(package_json, "devDependencies", %{})
    dev_script = if is_map(scripts), do: Map.get(scripts, "dev"), else: nil
    package_manager = detect_package_manager(workspace_path, package_json)
    framework = detect_framework(package_json, deps, dev_deps, dev_script)

    suggested =
      case {framework, package_manager, dev_script} do
        {"astro", manager, script} when is_binary(manager) and is_binary(script) ->
          %{
            suggested_setup_command: "#{manager} run dev --host 127.0.0.1 --port 4321 --strictPort",
            suggested_url: "http://127.0.0.1:4321/",
            note: "Astro dev defaults to port 4321; prefer screenshot capture for static page changes."
          }

        {framework_name, manager, script} ->
          %{
            suggested_setup_command: generic_setup_command(manager, script),
            suggested_url: nil,
            note: generic_demo_note(framework_name, manager, script)
          }
      end

    %{
      framework: framework,
      package_manager: package_manager,
      dev_script: dev_script,
      suggested_setup_command: suggested[:suggested_setup_command],
      suggested_url: suggested[:suggested_url],
      note: suggested[:note]
    }
  end

  defp maybe_context_line(_label, nil), do: nil
  defp maybe_context_line(label, value), do: "- #{label}: #{value}"

  defp detect_package_manager(workspace_path, package_json) do
    case Map.get(package_json, "packageManager") do
      value when is_binary(value) and value != "" ->
        value |> String.split("@") |> List.first()

      _ ->
        cond do
          File.exists?(Path.join(workspace_path, "pnpm-lock.yaml")) -> "pnpm"
          File.exists?(Path.join(workspace_path, "yarn.lock")) -> "yarn"
          File.exists?(Path.join(workspace_path, "bun.lock")) -> "bun"
          File.exists?(Path.join(workspace_path, "bun.lockb")) -> "bun"
          File.exists?(Path.join(workspace_path, "package-lock.json")) -> "npm"
          true -> nil
        end
    end
  end

  defp detect_framework(package_json, deps, dev_deps, dev_script) do
    package_name = Map.get(package_json, "name", "")

    cond do
      Map.has_key?(deps, "astro") or Map.has_key?(dev_deps, "astro") or
          (is_binary(dev_script) and String.contains?(dev_script, "astro dev")) ->
        "astro"

      Map.has_key?(deps, "next") or Map.has_key?(dev_deps, "next") or
          (is_binary(dev_script) and String.contains?(dev_script, "next dev")) ->
        "next"

      Map.has_key?(deps, "vite") or Map.has_key?(dev_deps, "vite") or
          (is_binary(dev_script) and String.contains?(dev_script, "vite")) ->
        "vite"

      Map.has_key?(deps, "gatsby") or Map.has_key?(dev_deps, "gatsby") ->
        "gatsby"

      is_binary(package_name) and package_name != "" ->
        package_name

      true ->
        nil
    end
  end

  defp generic_setup_command(manager, script)
       when is_binary(manager) and manager in ["npm", "pnpm", "yarn", "bun"] and is_binary(script) do
    case {manager, script} do
      {"npm", _} -> "npm run dev"
      {"pnpm", _} -> "pnpm dev"
      {"yarn", _} -> "yarn dev"
      {"bun", _} -> "bun run dev"
    end
  end

  defp generic_setup_command(_, _), do: nil

  defp generic_demo_note(framework, manager, script) do
    cond do
      is_binary(framework) and is_binary(script) ->
        "Inspect the repo's dev server behavior and choose an explicit host/port before writing the demo plan."

      is_binary(manager) ->
        "A package manager was detected, but the demo plan still needs to inspect the repo before choosing a host/port."

      true ->
        "No clear app-server context detected; only use local demo setup if you verify it from the workspace."
    end
  end
end
