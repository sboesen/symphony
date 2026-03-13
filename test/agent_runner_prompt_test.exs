defmodule Symphony.AgentRunnerPromptTest do
  use ExUnit.Case, async: true

  alias Symphony.{AgentRunnerPrompt, Issue}

  test "planning prompt includes issue context and rules" do
    issue = %Issue{
      identifier: "TEST-1",
      title: "Fix dashboard",
      url: "https://linear.app/issue/TEST-1",
      description: "Update dashboard layout",
      comments_text: "latest correction",
      feedback_assets_text: "asset notes"
    }

    prompt = AgentRunnerPrompt.planning_prompt(issue)
    assert prompt =~ "Issue: TEST-1 - Fix dashboard"
    assert prompt =~ "Write a valid JSON work plan"
    assert prompt =~ "asset notes"
  end

  test "comment and feedback context append only when present" do
    issue = %Issue{comments_text: "new direction", feedback_assets_text: "image context"}
    assert AgentRunnerPrompt.append_comment_context("base", issue) =~ "Recent human feedback:"
    assert AgentRunnerPrompt.append_feedback_context("base", issue) =~ "Additional feedback context:"

    blank = %Issue{comments_text: "", feedback_assets_text: nil}
    assert AgentRunnerPrompt.append_comment_context("base", blank) == "base"
    assert AgentRunnerPrompt.append_feedback_context("base", blank) == "base"
  end

  test "plan repair prompt keeps the no-code-change contract" do
    issue = %Issue{identifier: "TEST-2", title: "Repair"}
    prompt = AgentRunnerPrompt.plan_repair_prompt(issue)
    assert prompt =~ "Update only `.git/symphony/plan.json`"
    assert prompt =~ "Do not make product code changes."
  end

  test "plan context renders existing plan and ignores invalid files" do
    root = Path.join(System.tmp_dir!(), "symphony-prompt-#{System.unique_integer([:positive])}")
    symphony = Path.join(root, ".git/symphony")
    File.mkdir_p!(symphony)

    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(Path.join(symphony, "plan.json"), Jason.encode!(%{"summary" => "Plan", "steps" => [%{"id" => "1", "content" => "Ship", "status" => "pending"}]}))
    assert AgentRunnerPrompt.append_plan_context("base", root) =~ "Ship"

    File.write!(Path.join(symphony, "plan.json"), "{")
    assert AgentRunnerPrompt.append_plan_context("base", root) == "base"
  end

  test "completion prompt includes demo contract only when recording is enabled" do
    root = Path.join(System.tmp_dir!(), "symphony-prompt-demo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "package.json"), Jason.encode!(%{"name" => "demo-app", "scripts" => %{"dev" => "vite"}}))
    File.write!(Path.join(root, "package-lock.json"), "")

    on_exit(fn -> File.rm_rf!(root) end)

    base_prompt = AgentRunnerPrompt.append_completion_prompt("base", %{recording_enabled: false, recording_url: nil}, root)
    assert base_prompt =~ "Completion contract:"
    refute base_prompt =~ "Demo recording requirement:"

    demo_prompt = AgentRunnerPrompt.append_completion_prompt("base", %{recording_enabled: true, recording_url: "http://127.0.0.1:4000"}, root)
    assert demo_prompt =~ "Demo recording requirement:"
    assert demo_prompt =~ "http://127.0.0.1:4000"
    assert demo_prompt =~ "Repo demo context:"
  end
end
