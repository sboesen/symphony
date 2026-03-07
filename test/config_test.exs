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
    assert config.github_webhook_auto_register == false
  end
end
