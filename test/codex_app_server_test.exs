defmodule Symphony.CodexAppServerTest do
  use ExUnit.Case, async: true

  alias Symphony.CodexAppServer

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-codex-app-server-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)

    script_path = Path.join(workspace, "fake-codex-app-server")

    File.write!(
      script_path,
      """
      #!/usr/bin/env python3
      import json, sys

      for raw in sys.stdin:
          line = raw.strip()
          if not line:
              continue
          payload = json.loads(line)
          method = payload.get("method")

          if method == "initialize":
              print(json.dumps({"jsonrpc": "2.0", "id": payload["id"], "result": {"ok": True}}), flush=True)
          elif method == "thread/start":
              print(json.dumps({
                  "jsonrpc": "2.0",
                  "id": payload["id"],
                  "result": {
                      "thread": {"id": "thread-1", "tokenUsage": {"last": {"inputTokens": 5, "outputTokens": 7, "totalTokens": 12}}}
                  }
              }), flush=True)
          elif method == "turn/start":
              print(json.dumps({
                  "jsonrpc": "2.0",
                  "method": "turn/completed",
                  "params": {
                      "turn": {"id": "turn-1", "status": "completed"},
                      "tokenUsage": {"last": {"inputTokens": 11, "outputTokens": 13, "totalTokens": 24}}
                  }
              }), flush=True)
              break
      """
    )

    File.chmod!(script_path, 0o755)

    on_exit(fn ->
      File.rm_rf!(workspace)
    end)

    %{workspace: workspace, script_path: script_path}
  end

  test "completes a turn from JSON-RPC events", %{workspace: workspace, script_path: script_path} do
    config = %Symphony.Config{
      turn_timeout_ms: 5_000,
      read_timeout_ms: 100,
      codex_command: script_path,
      codex_router_default_provider: "codex",
      codex_model: "gpt-5",
      codex_model_provider: "openai",
      codex_profiles: %{},
      openai_api_key: nil,
      zai_api_key: nil,
      openai_base_url: nil
    }

    assert {:ok, %{session_id: "thread-1-turn-1", usage: usage}} =
             CodexAppServer.run_turn(
               workspace,
               config,
               nil,
               1,
               "test prompt",
               %{provider: "codex", model: "gpt-5", model_provider: "openai"},
               fn _ -> :ok end
             )

    assert usage == %{input_tokens: 11, output_tokens: 13, total_tokens: 24}
  end
end
