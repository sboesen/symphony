defmodule Symphony.ConfigTest do
  use ExUnit.Case, async: true

  test "enables github webhook auto register when config is complete" do
    workflow = %Symphony.Workflow{
      config: %{
        "github" => %{
          "webhook" => %{
            "secret" => "secret-value",
            "provider" => "ngrok",
            "repo" => "sboesen/blog.boesen.me"
          }
        },
        "codex" => %{
          "providers" => %{
            "zai" => %{
              "backend" => "opencode",
              "command" => "opencode",
              "auth_mode" => "api_key",
              "api_key" => "z-key",
              "base_url" => "https://api.z.ai/api/coding/paas/v4",
              "model" => "zai-coding-plan/glm-5"
            }
          }
        }
      }
    }

    assert {:ok, config} = Symphony.Config.from_workflow(workflow)
    assert config.github_webhook_auto_register == true
    assert config.github_webhook_provider == "ngrok"
    assert config.github_webhook_repo == "sboesen/blog.boesen.me"
  end

  test "does not enable github webhook auto register when secret is missing" do
    workflow = %Symphony.Workflow{
      config: %{
        "github" => %{
          "webhook" => %{
            "provider" => "ngrok",
            "repo" => "sboesen/blog.boesen.me"
          }
        }
      }
    }

    assert {:ok, config} = Symphony.Config.from_workflow(workflow)
    assert is_binary(config.github_webhook_secret)
    assert config.github_webhook_secret != ""
    assert config.github_webhook_auto_register == true
  end

  test "enables linear webhook auto register when project and secret are configured" do
    workflow = %Symphony.Workflow{
      config: %{
        "tracker" => %{"project_slug" => "b88fe441c568"},
        "github" => %{
          "webhook" => %{
            "secret" => "shared-secret",
            "provider" => "ngrok",
            "repo" => "sboesen/blog.boesen.me"
          }
        }
      }
    }

    assert {:ok, config} = Symphony.Config.from_workflow(workflow)
    assert config.linear_webhook_auto_register == true
    assert config.linear_webhook_secret == "shared-secret"
  end

  test "supports disabling reconciliation polling explicitly" do
    workflow = %Symphony.Workflow{
      config: %{
        "polling" => %{
          "enabled" => false,
          "interval_ms" => 300_000
        }
      }
    }

    assert {:ok, config} = Symphony.Config.from_workflow(workflow)
    assert config.poll_enabled == false
    assert config.poll_interval_ms == 300_000
  end

  test "generates an ephemeral linear webhook secret for webhook-only local mode" do
    workflow = %Symphony.Workflow{
      config: %{
        "tracker" => %{"project_slug" => "b88fe441c568"},
        "polling" => %{"enabled" => false}
      }
    }

    assert {:ok, config} = Symphony.Config.from_workflow(workflow)
    assert is_binary(config.linear_webhook_secret)
    assert config.linear_webhook_secret != ""
  end

  test "reuses the same derived webhook secret across local sessions for the same project and repo" do
    System.put_env("LINEAR_API_KEY", "linear-test-key")

    on_exit(fn ->
      System.delete_env("LINEAR_API_KEY")
    end)

    workflow = %Symphony.Workflow{
      config: %{
        "tracker" => %{"project_slug" => "b88fe441c568"},
        "github" => %{
          "webhook" => %{
            "provider" => "ngrok",
            "repo" => "sboesen/blog.boesen.me"
          }
        }
      }
    }

    assert {:ok, config_a} = Symphony.Config.from_workflow(workflow)
    assert {:ok, config_b} = Symphony.Config.from_workflow(workflow)

    assert config_a.github_webhook_secret == config_b.github_webhook_secret
    assert config_a.linear_webhook_secret == config_b.linear_webhook_secret
  end

  test "generates a fresh fallback webhook secret when no stable local inputs are configured" do
    env_keys = [
      "LINEAR_API_KEY",
      "LINEAR_PROJECT_SLUG",
      "GITHUB_REPO_URL",
      "GITHUB_WEBHOOK_SECRET",
      "LINEAR_WEBHOOK_SECRET"
    ]

    saved_env = Map.new(env_keys, fn key -> {key, System.get_env(key)} end)
    Enum.each(env_keys, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    workflow = %Symphony.Workflow{config: %{}}

    assert {:ok, config_a} = Symphony.Config.from_workflow(workflow)
    assert {:ok, config_b} = Symphony.Config.from_workflow(workflow)

    assert config_a.github_webhook_secret != config_b.github_webhook_secret
    assert config_a.linear_webhook_secret != config_b.linear_webhook_secret
  end

  test "defaults review handoff to human review with auto-merge disabled" do
    workflow = %Symphony.Workflow{config: %{}}

    assert {:ok, config} = Symphony.Config.from_workflow(workflow)
    assert config.review_required == true
    assert config.review_pr_auto_merge == false
  end

  test "--no-review mode restores the old fast path defaults" do
    System.put_env("SYMPHONY_NO_REVIEW", "true")

    on_exit(fn ->
      System.delete_env("SYMPHONY_NO_REVIEW")
    end)

    workflow = %Symphony.Workflow{config: %{}}

    assert {:ok, config} = Symphony.Config.from_workflow(workflow)
    assert config.review_required == false
    assert config.review_pr_auto_merge == true
  end
end
