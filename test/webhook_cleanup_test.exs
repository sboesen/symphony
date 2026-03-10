defmodule Symphony.WebhookCleanupTest do
  use ExUnit.Case, async: false

  alias Plug.Conn

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-webhook-cleanup-#{System.unique_integer([:positive])}"
      )

    bin_dir = Path.join(workspace, "bin")
    File.mkdir_p!(bin_dir)
    gh_log = Path.join(workspace, "gh.log")
    gh_path = Path.join(bin_dir, "gh")

    File.write!(
      gh_path,
      """
      #!/bin/bash
      printf '%s\n' "$*" >> "#{gh_log}"
      if [ "$1" = "api" ] && [ "$2" = "repos/example/repo/hooks" ]; then
        printf '%s' '[{"id":1,"config":{"url":"https://x.test/api/v1/github/webhook"}},{"id":2,"config":{"url":"https://x.test/other"}}]'
        exit 0
      fi
      exit 0
      """
    )

    File.chmod!(gh_path, 0o755)

    original_path = System.get_env("PATH") || ""
    System.put_env("PATH", bin_dir <> ":" <> original_path)

    parent = self()
    ref = make_ref()
    Application.put_env(:symphony, :webhook_cleanup_test_pid, parent)

    {:ok, _pid} =
      Plug.Cowboy.http(__MODULE__.Router, [], ip: {127, 0, 0, 1}, port: 0, ref: ref)

    port = :ranch.get_port(ref)

    on_exit(fn ->
      System.put_env("PATH", original_path)
      Application.delete_env(:symphony, :webhook_cleanup_test_pid)
      Plug.Cowboy.shutdown(ref)
      File.rm_rf!(workspace)
    end)

    config = %Symphony.Config{
      tracker_endpoint: "http://127.0.0.1:#{port}",
      tracker_api_key: "linear-key"
    }

    %{config: config, gh_log: gh_log}
  end

  test "cleans up matching GitHub webhooks", %{gh_log: gh_log} do
    assert :ok = Symphony.WebhookCleanup.cleanup_github_hooks("example/repo")
    assert {:ok, log} = File.read(gh_log)
    assert log =~ "api repos/example/repo/hooks"
    assert log =~ "api --method DELETE repos/example/repo/hooks/1"
    refute log =~ "hooks/2"
  end

  test "cleans up matching Linear webhooks", %{config: config} do
    assert :ok = Symphony.WebhookCleanup.cleanup_linear_hooks(config, "project-1")

    assert_receive {:linear_query, %{"query" => query}} when is_binary(query)
    assert_receive {:linear_delete, %{"id" => "hook-1"}}
    refute_receive {:linear_delete, %{"id" => "hook-2"}}
  end

  test "cleanup/2 handles both webhook kinds", %{config: config, gh_log: gh_log} do
    assert :ok =
             Symphony.WebhookCleanup.cleanup(config,
               repo_slug: "example/repo",
               project_slug: "project-1"
             )

    assert {:ok, log} = File.read(gh_log)
    assert log =~ "repos/example/repo/hooks"
    assert_receive {:linear_delete, %{"id" => "hook-1"}}
  end

  defmodule Router do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/" do
      {:ok, raw, conn} = Conn.read_body(conn)
      {:ok, payload} = Jason.decode(raw)
      test_pid = Application.fetch_env!(:symphony, :webhook_cleanup_test_pid)
      query = payload["query"] || ""

      response =
        cond do
          String.contains?(query, "webhooks(first: 100)") ->
            send(test_pid, {:linear_query, payload})

            %{
              "data" => %{
                "webhooks" => %{
                  "nodes" => [
                    %{
                      "id" => "hook-1",
                      "label" => "Symphony local webhook (project-1)",
                      "url" => "https://x.test/linear/webhook/project-1",
                      "enabled" => true,
                      "team" => %{"id" => "t1", "key" => "T", "name" => "Team"}
                    },
                    %{
                      "id" => "hook-2",
                      "label" => "Other",
                      "url" => "https://x.test/linear/webhook/other",
                      "enabled" => true,
                      "team" => %{"id" => "t1", "key" => "T", "name" => "Team"}
                    }
                  ]
                }
              }
            }

          String.contains?(query, "webhookDelete") ->
            send(test_pid, {:linear_delete, payload["variables"] || %{}})
            %{"data" => %{"webhookDelete" => %{"success" => true}}}
        end

      Conn.send_resp(conn, 200, Jason.encode!(response))
    end
  end
end
