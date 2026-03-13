defmodule Symphony.CLIInteractiveTest do
  use ExUnit.Case, async: true

  alias Symphony.CLIInteractive

  test "resolve_defaults is a no-op for non-linear trackers" do
    parsed = %{project_slug: nil, repo_url: nil}
    config = %{tracker_kind: "mock", tracker_project_slug: nil}

    assert {:ok, ^parsed} = CLIInteractive.resolve_defaults(parsed, config)
  end

  test "resolve_defaults prefers explicit project and repo values" do
    parsed = %{project_slug: "proj-1", repo_url: "https://github.com/acme/repo"}
    config = %{tracker_kind: "linear", tracker_project_slug: "fallback"}
    project = %{slug_id: "proj-1", repo_url: nil}

    assert {:ok, %{project_slug: "proj-1", repo_url: "git@github.com:acme/repo.git"}} =
             CLIInteractive.resolve_defaults(parsed, config,
               tracker_fetch_project_by_slug: fn ^config, "proj-1" -> {:ok, project} end,
               github_normalize_to_ssh: fn "https://github.com/acme/repo" ->
                 {:ok, "git@github.com:acme/repo.git"}
               end,
               github_slug_from_ssh: fn "git@github.com:acme/repo.git" -> {:ok, "acme/repo"} end,
               tracker_save_project_repo: fn ^config, ^project, "git@github.com:acme/repo.git" ->
                 {:ok, %{project | repo_url: "git@github.com:acme/repo.git"}}
               end
             )
  end

  test "resolve_defaults uses configured project and env repo when missing from args" do
    config = %{tracker_kind: "linear", tracker_project_slug: "proj-2"}
    parsed = %{project_slug: nil, repo_url: nil}
    project = %{slug_id: "proj-2", repo_url: "git@github.com:acme/repo.git"}

    assert {:ok, %{project_slug: "proj-2", repo_url: "git@github.com:acme/repo.git"}} =
             CLIInteractive.resolve_defaults(parsed, config,
               env_get: fn "GITHUB_REPO_URL" -> "git@github.com:acme/repo.git" end,
               tracker_fetch_project_by_slug: fn ^config, "proj-2" -> {:ok, project} end,
               github_normalize_to_ssh: fn "git@github.com:acme/repo.git" ->
                 {:ok, "git@github.com:acme/repo.git"}
               end,
               github_slug_from_ssh: fn "git@github.com:acme/repo.git" -> {:ok, "acme/repo"} end
             )
  end

  test "ensure_project lists and prompts when project slug is missing" do
    config = %{tracker_kind: "linear"}
    projects = [%{name: "Beta", slug_id: "beta"}, %{name: "Alpha", slug_id: "alpha", team_keys: ["ENG"]}]
    {:ok, output} = Agent.start_link(fn -> [] end)

    assert {:ok, %{slug_id: "alpha"}, "alpha"} =
             CLIInteractive.ensure_project(config, nil,
               tracker_list_projects: fn ^config -> {:ok, projects} end,
               read_prompt: fn "Project number: " -> {:ok, "1"} end,
               puts: fn line ->
                 Agent.update(output, &[line | &1])
                 :ok
               end
             )

    assert Enum.reverse(Agent.get(output, & &1)) == [
             "Select a Linear project:",
             "  1. Alpha [ENG] (alpha)",
             "  2. Beta (beta)"
           ]
  end

  test "ensure_repo reuses persisted project repo without saving" do
    config = %{tracker_kind: "linear"}
    project = %{slug_id: "proj-1", repo_url: "git@github.com:acme/repo.git"}

    assert {:ok, "git@github.com:acme/repo.git"} =
             CLIInteractive.ensure_repo(config, project, nil,
               github_normalize_to_ssh: fn value -> {:ok, value} end,
               github_slug_from_ssh: fn _ -> {:ok, "acme/repo"} end,
               tracker_save_project_repo: fn _, _, _ -> flunk("should not persist") end
             )
  end

  test "ensure_repo prompts and persists when project has no repo" do
    config = %{tracker_kind: "linear"}
    project = %{slug_id: "proj-1", repo_url: nil}

    assert {:ok, "git@github.com:acme/repo.git"} =
             CLIInteractive.ensure_repo(config, project, nil,
               read_prompt: fn "GitHub repo (https://github.com/org/repo or git@github.com:org/repo.git): " ->
                 {:ok, "https://github.com/acme/repo"}
               end,
               github_normalize_to_ssh: fn "https://github.com/acme/repo" ->
                 {:ok, "git@github.com:acme/repo.git"}
               end,
               github_slug_from_ssh: fn "git@github.com:acme/repo.git" -> {:ok, "acme/repo"} end,
               tracker_save_project_repo: fn ^config, ^project, "git@github.com:acme/repo.git" ->
                 {:ok, %{project | repo_url: "git@github.com:acme/repo.git"}}
               end
             )
  end

  test "prompt_until_valid retries on string errors and stops on prompt failures" do
    {:ok, output} = Agent.start_link(fn -> [] end)
    {:ok, prompts} = Agent.start_link(fn -> ["bad", "2"] end)

    assert {:ok, 2} =
             CLIInteractive.prompt_until_valid("Value: ",
               %{
                 read_prompt: fn "Value: " ->
                   Agent.get_and_update(prompts, fn
                     [next | rest] -> {{:ok, next}, rest}
                     [] -> {{:error, :interactive_input_required}, []}
                   end)
                 end,
                 puts: fn line ->
                   Agent.update(output, &[line | &1])
                   :ok
                 end
               },
               fn
                 "2" -> {:ok, 2}
                 _ -> {:error, "retry"}
               end
             )

    assert Agent.get(output, &Enum.reverse(&1)) == ["retry"]
    assert {:error, :interactive_input_required} =
             CLIInteractive.prompt_until_valid("Value: ", %{read_prompt: fn _ -> {:error, :interactive_input_required} end}, fn _ ->
               {:ok, :ignored}
             end)
  end

  test "read_prompt trims input and maps eof to interactive error" do
    assert {:ok, "hello"} =
             CLIInteractive.read_prompt("Prompt: ",
               write: fn _ -> :ok end,
               gets: fn "" -> "  hello \n" end
             )

    assert {:error, :interactive_input_required} =
             CLIInteractive.read_prompt("Prompt: ",
               write: fn _ -> :ok end,
               gets: fn "" -> :eof end
             )
  end
end
