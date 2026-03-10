defmodule Symphony.CLITest do
  use ExUnit.Case, async: false

  test "parses runtime args from flags and positional workflow" do
    parsed =
      Symphony.CLI.parse_runtime_args([
        "custom.md",
        "--project-slug",
        "project-1",
        "--repo",
        "https://github.com/acme/repo",
        "--linear-api-key",
        "linear-key",
        "--port",
        "4040",
        "--no-review"
      ])

    assert parsed.workflow_path == "custom.md"
    assert parsed.project_slug == "project-1"
    assert parsed.repo_url == "https://github.com/acme/repo"
    assert parsed.linear_api_key == "linear-key"
    assert parsed.port == 4040
    assert parsed.no_review? == true
  end

  test "applies runtime overrides into the environment" do
    on_exit(fn ->
      for key <- [
            "LINEAR_PROJECT_SLUG",
            "GITHUB_REPO_URL",
            "GITHUB_WEBHOOK_REPO",
            "LINEAR_API_KEY",
            "SYMPHONY_SERVER_PORT",
            "SYMPHONY_NO_REVIEW"
          ] do
        System.delete_env(key)
      end
    end)

    parsed = %{
      project_slug: "project-1",
      repo_url: "git@github.com:acme/repo.git",
      linear_api_key: "linear-key",
      port: 4040,
      no_review?: true
    }

    assert :ok = Symphony.CLI.apply_runtime_overrides(parsed)
    assert System.get_env("LINEAR_PROJECT_SLUG") == "project-1"
    assert System.get_env("GITHUB_REPO_URL") == "git@github.com:acme/repo.git"
    assert System.get_env("GITHUB_WEBHOOK_REPO") == "acme/repo"
    assert System.get_env("LINEAR_API_KEY") == "linear-key"
    assert System.get_env("SYMPHONY_SERVER_PORT") == "4040"
    assert System.get_env("SYMPHONY_NO_REVIEW") == "true"
  end

  test "cleanup_runtime_file removes the runtime file" do
    runtime_path =
      Path.join(System.tmp_dir!(), "symphony-runtime-#{System.unique_integer([:positive])}.json")

    workflow_path =
      Path.join(System.tmp_dir!(), "symphony-workflow-#{System.unique_integer([:positive])}.md")

    File.write!(runtime_path, Jason.encode!(%{"project_slug" => nil, "repo_url" => nil}))

    File.write!(workflow_path, """
    tracker:
      kind: mock
      mock_file: ./tmp/mock.json
    """)

    on_exit(fn ->
      File.rm(runtime_path)
      File.rm(workflow_path)
    end)

    assert :ok = Symphony.CLI.cleanup_runtime_file(runtime_path, workflow_path)
    refute File.exists?(runtime_path)
  end

  test "parse_runtime_args keeps defaults and normalizes blank overrides" do
    parsed =
      Symphony.CLI.parse_runtime_args([
        "--workflow",
        "  ./alt-workflow.md  ",
        "--project-slug",
        "   ",
        "--repo",
        "   ",
        "--linear-api-key",
        "  ",
        "--port",
        "5050"
      ])

    assert parsed.help? == false
    assert parsed.workflow_path == "./alt-workflow.md"
    assert parsed.project_slug == nil
    assert parsed.repo_url == nil
    assert parsed.linear_api_key == nil
    assert parsed.port == 5050
    assert parsed.no_review? == false
  end

  test "apply_runtime_overrides clears no-review and ignores invalid repo slugs" do
    System.put_env("SYMPHONY_NO_REVIEW", "true")
    System.delete_env("GITHUB_WEBHOOK_REPO")

    on_exit(fn ->
      System.delete_env("SYMPHONY_NO_REVIEW")
      System.delete_env("GITHUB_WEBHOOK_REPO")
      System.delete_env("GITHUB_REPO_URL")
    end)

    parsed = %{
      project_slug: nil,
      repo_url: "not-a-github-repo",
      linear_api_key: nil,
      port: nil,
      no_review?: false
    }

    assert :ok = Symphony.CLI.apply_runtime_overrides(parsed)
    assert System.get_env("GITHUB_REPO_URL") == "not-a-github-repo"
    assert System.get_env("GITHUB_WEBHOOK_REPO") == nil
    assert System.get_env("SYMPHONY_NO_REVIEW") == nil
  end

  test "cleanup_runtime_file removes matching project lock files" do
    runtime_path =
      Path.join(System.tmp_dir!(), "symphony-runtime-#{System.unique_integer([:positive])}.json")

    workflow_path =
      Path.join(System.tmp_dir!(), "symphony-workflow-#{System.unique_integer([:positive])}.md")

    lock_path = Path.join(System.tmp_dir!(), "symphony-project-project-1.lock")

    File.write!(
      runtime_path,
      Jason.encode!(%{"project_slug" => "project-1", "repo_url" => "git@github.com:acme/repo.git"})
    )

    File.write!(workflow_path, """
    tracker:
      kind: mock
      mock_file: ./tmp/mock.json
    """)

    File.write!(lock_path, "999999")

    on_exit(fn ->
      File.rm(runtime_path)
      File.rm(workflow_path)
      File.rm(lock_path)
    end)

    assert :ok = Symphony.CLI.cleanup_runtime_file(runtime_path, workflow_path)
    refute File.exists?(runtime_path)
    refute File.exists?(lock_path)
  end
end
