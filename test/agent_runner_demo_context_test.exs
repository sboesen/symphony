defmodule Symphony.AgentRunnerDemoContextTest do
  use ExUnit.Case, async: false

  alias Symphony.AgentRunnerDemoContext

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "symphony-demo-context-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(workspace) end)

    %{workspace: workspace}
  end

  test "prompt falls back when no package metadata exists", %{workspace: workspace} do
    assert AgentRunnerDemoContext.prompt(workspace) =~ "none detected"
    assert AgentRunnerDemoContext.detect(workspace) == nil
  end

  test "detect builds astro suggestions from package manager metadata", %{workspace: workspace} do
    File.write!(
      Path.join(workspace, "package.json"),
      Jason.encode!(%{
        "packageManager" => "pnpm@9.0.0",
        "dependencies" => %{"astro" => "^4.0.0"},
        "scripts" => %{"dev" => "astro dev"}
      })
    )

    context = AgentRunnerDemoContext.detect(workspace)

    assert context.framework == "astro"
    assert context.package_manager == "pnpm"
    assert context.dev_script == "astro dev"
    assert context.suggested_setup_command == "pnpm run dev --host 127.0.0.1 --port 4321 --strictPort"
    assert context.suggested_url == "http://127.0.0.1:4321/"
    assert context.note =~ "Astro dev defaults"
  end

  test "detect uses lockfiles and scripts for non-astro repos", %{workspace: workspace} do
    File.write!(
      Path.join(workspace, "package.json"),
      Jason.encode!(%{
        "name" => "demo-app",
        "devDependencies" => %{"vite" => "^5.0.0"},
        "scripts" => %{"dev" => "vite"}
      })
    )

    File.write!(Path.join(workspace, "yarn.lock"), "")

    context = AgentRunnerDemoContext.detect(workspace)

    assert context.framework == "vite"
    assert context.package_manager == "yarn"
    assert context.suggested_setup_command == "yarn dev"
    assert context.suggested_url == nil
    assert context.note =~ "Inspect the repo's dev server behavior"
  end

  test "prompt renders context lines for detected repos", %{workspace: workspace} do
    File.write!(
      Path.join(workspace, "package.json"),
      Jason.encode!(%{
        "name" => "demo-app",
        "scripts" => %{"dev" => "custom-dev"}
      })
    )

    File.write!(Path.join(workspace, "package-lock.json"), "")

    prompt = AgentRunnerDemoContext.prompt(workspace)

    assert prompt =~ "Repo demo context:"
    assert prompt =~ "Likely package manager"
    assert prompt =~ "npm"
    assert prompt =~ "Detected dev script"
    assert prompt =~ "custom-dev"
    assert prompt =~ "Inspect the repo's dev server behavior"
  end
end
