defmodule Symphony.GitHubWebhookReconcilerTest do
  use ExUnit.Case, async: true

  alias Symphony.GitHubWebhookReconciler

  test "desired_github_repos filters blanks and deduplicates" do
    sessions = [
      %{repo: "acme/repo"},
      %{"repo" => "acme/repo"},
      %{repo: ""},
      %{}
    ]

    assert GitHubWebhookReconciler.desired_github_repos(sessions) == ["acme/repo"]
  end

  test "desired_linear_projects keeps unique valid project/session pairs" do
    sessions = [
      %{project_slug: "proj-1", session_id: "s1"},
      %{"project_slug" => "proj-1", "session_id" => "s2"},
      %{project_slug: "proj-2", session_id: ""},
      %{project_slug: nil, session_id: "s3"},
      %{project_slug: "proj-3", session_id: "s3"}
    ]

    assert GitHubWebhookReconciler.desired_linear_projects(sessions) == [
             %{project_slug: "proj-1", session_id: "s1"},
             %{project_slug: "proj-3", session_id: "s3"}
           ]
  end

  test "reconcile_desired_github_hooks removes stale hooks and reuses matching callbacks" do
    {:ok, cleaned} = Agent.start_link(fn -> [] end)

    current = %{
      "drop/repo" => %{id: 1, repo: "drop/repo", callback: "https://old/github/webhook"},
      "keep/repo" => %{id: 2, repo: "keep/repo", callback: "https://new/github/webhook"}
    }

    assert {:ok, next} =
             GitHubWebhookReconciler.reconcile_desired_github_hooks(
               current,
               ["keep/repo"],
               "secret",
               "https://new/github/webhook",
               cleanup_github_webhook: fn hook ->
                 Agent.update(cleaned, &[{:cleanup, hook.repo} | &1])
                 :ok
               end,
               create_github_webhook: fn _, _, _ -> flunk("should not create") end
             )

    assert next == %{
             "keep/repo" => %{id: 2, repo: "keep/repo", callback: "https://new/github/webhook"}
           }

    assert Agent.get(cleaned, &Enum.reverse(&1)) == [{:cleanup, "drop/repo"}]
  end

  test "reconcile_desired_github_hooks recreates mismatched hooks and halts on create errors" do
    {:ok, cleaned} = Agent.start_link(fn -> [] end)
    {:ok, old_cleaned} = Agent.start_link(fn -> [] end)

    assert {:ok, %{"acme/repo" => %{id: 123, repo: "acme/repo", callback: "https://new/github/webhook"}}} =
             GitHubWebhookReconciler.reconcile_desired_github_hooks(
               %{"acme/repo" => %{id: 1, repo: "acme/repo", callback: "https://old/github/webhook"}},
               ["acme/repo"],
               "secret",
               "https://new/github/webhook",
               cleanup_github_webhook: fn hook ->
                 Agent.update(cleaned, &[hook.id | &1])
                 :ok
               end,
               cleanup_old_symphony_github_hooks: fn repo ->
                 Agent.update(old_cleaned, &[repo | &1])
                 :ok
               end,
               create_github_webhook: fn "acme/repo", "secret", "https://new/github/webhook" -> {:ok, 123} end,
               log_info: fn _ -> :ok end
             )

    assert Agent.get(cleaned, &Enum.reverse(&1)) == [1]
    assert Agent.get(old_cleaned, &Enum.reverse(&1)) == ["acme/repo"]

    assert {:error, :boom} =
             GitHubWebhookReconciler.reconcile_desired_github_hooks(
               %{},
               ["acme/repo"],
               "secret",
               "https://new/github/webhook",
               create_github_webhook: fn _, _, _ -> {:error, :boom} end
             )
  end

  test "reconcile_desired_linear_hooks removes stale hooks and reuses matching callbacks" do
    {:ok, cleaned} = Agent.start_link(fn -> [] end)
    config = %{tracker_kind: "linear"}

    current = %{
      "drop" => %{id: "1", project_slug: "drop", callback: "https://old/linear/webhook/drop"},
      "keep" => %{id: "2", project_slug: "keep", callback: "https://new/linear/webhook/keep"}
    }

    desired = [%{project_slug: "keep", session_id: "s1"}]

    assert {:ok, next} =
             GitHubWebhookReconciler.reconcile_desired_linear_hooks(
               current,
               desired,
               "secret",
               "https://new",
               config,
               cleanup_linear_webhook: fn ^config, hook ->
                 Agent.update(cleaned, &[{:cleanup, hook.project_slug} | &1])
                 :ok
               end,
               create_linear_webhook: fn _, _, _, _ -> flunk("should not create") end
             )

    assert next == %{
             "keep" => %{id: "2", project_slug: "keep", callback: "https://new/linear/webhook/keep"}
           }

    assert Agent.get(cleaned, &Enum.reverse(&1)) == [{:cleanup, "drop"}]
  end

  test "reconcile_desired_linear_hooks recreates mismatched hooks and preserves callback shape" do
    {:ok, cleaned} = Agent.start_link(fn -> [] end)
    {:ok, old_cleaned} = Agent.start_link(fn -> [] end)
    config = %{tracker_kind: "linear"}

    assert {:ok, %{"proj-1" => %{id: "hook-1", project_slug: "proj-1", callback: "https://ngrok/linear/webhook/proj-1"}}} =
             GitHubWebhookReconciler.reconcile_desired_linear_hooks(
               %{"proj-1" => %{id: "old", project_slug: "proj-1", callback: "https://old/linear/webhook/proj-1"}},
               [%{project_slug: "proj-1", session_id: "s1"}],
               "secret",
               "https://ngrok",
               config,
               cleanup_linear_webhook: fn ^config, hook ->
                 Agent.update(cleaned, &[hook.id | &1])
                 :ok
               end,
               cleanup_old_symphony_linear_hooks: fn ^config, slug ->
                 Agent.update(old_cleaned, &[slug | &1])
                 :ok
               end,
               create_linear_webhook: fn ^config, "proj-1", "secret", "https://ngrok/linear/webhook/proj-1" ->
                 {:ok, %{id: "hook-1"}}
               end,
               log_info: fn _ -> :ok end
             )

    assert Agent.get(cleaned, &Enum.reverse(&1)) == ["old"]
    assert Agent.get(old_cleaned, &Enum.reverse(&1)) == ["proj-1"]
  end
end
