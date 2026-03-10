defmodule Symphony.OpenCodeServerRunnerTest do
  use ExUnit.Case, async: true

  alias Symphony.OpenCodeServerRunner

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-open-code-server-runner-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)

    script_path = Path.join(workspace, "fake-opencode-server")

    File.write!(
      script_path,
      """
      #!/usr/bin/env python3
      import json, sys, threading
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
      from urllib.parse import urlparse

      port = 4096
      args = sys.argv[1:]
      for i, arg in enumerate(args):
          if arg == "--port" and i + 1 < len(args):
              port = int(args[i + 1])

      state = {
          "prompted": False,
          "disposed": False,
      }

      class Handler(BaseHTTPRequestHandler):
          def _send(self, status, payload):
              body = json.dumps(payload).encode()
              self.send_response(status)
              self.send_header("Content-Type", "application/json")
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)

          def do_GET(self):
              path = urlparse(self.path).path
              if path == "/global/health":
                  self._send(200, {"healthy": True})
              elif path.startswith("/session/session-1/message"):
                  if state["prompted"]:
                      self._send(200, [{
                          "parts": [{"type": "text", "text": "done"}],
                          "info": {
                              "role": "assistant",
                              "finish": "stop",
                              "tokens": {"input": 2, "output": 3, "total": 5},
                              "time": {"completed": 1}
                          }
                      }])
                  else:
                      self._send(200, [])
              elif path == "/session/status":
                  self._send(200, {"session-1": {"type": "running"}})
              else:
                  self._send(404, {"error": "missing"})

          def do_POST(self):
              path = urlparse(self.path).path
              length = int(self.headers.get("Content-Length", "0"))
              body = self.rfile.read(length).decode() if length else "{}"
              payload = json.loads(body)

              if path == "/session":
                  self._send(200, {"id": "session-1"})
              elif path == "/session/session-1/prompt_async":
                  state["prompted"] = True
                  self.send_response(204)
                  self.end_headers()
              elif path == "/session/session-1/abort":
                  self.send_response(204)
                  self.end_headers()
              elif path == "/global/dispose":
                  state["disposed"] = True
                  self.send_response(204)
                  self.end_headers()
                  threading.Thread(target=httpd.shutdown, daemon=True).start()
              else:
                  self._send(404, {"error": "missing"})

          def log_message(self, format, *args):
              return

      httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
      httpd.serve_forever()
      """
    )

    File.chmod!(script_path, 0o755)

    on_exit(fn ->
      File.rm_rf!(workspace)
    end)

    %{workspace: workspace, script_path: script_path}
  end

  test "completes a turn against the headless opencode server", %{
    workspace: workspace,
    script_path: script_path
  } do
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

    assert {:ok, %{session_id: "session-1", usage: usage}} =
             OpenCodeServerRunner.run_turn(
               workspace,
               config,
               %Symphony.Issue{identifier: "TEST-1", title: "Issue"},
               1,
               "test prompt",
               %{provider: "codex", model: "gpt-5", effort: "medium"},
               fn _ -> :ok end
             )

    assert usage == %{input_tokens: 2, output_tokens: 3, total_tokens: 5}
  end
end
