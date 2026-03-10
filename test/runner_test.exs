defmodule Symphony.RunnerTest do
  use ExUnit.Case, async: true

  alias Symphony.Runner

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "symphony-runner-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, ".git/symphony"))

    codex_app = Path.join(workspace, "fake-codex-app")
    codex_exec = Path.join(workspace, "fake-codex-exec")
    opencode = Path.join(workspace, "fake-opencode")
    opencode_server = Path.join(workspace, "fake-opencode-server")

    File.write!(
      codex_app,
      """
      #!/usr/bin/env python3
      import json, sys
      for raw in sys.stdin:
          payload = json.loads(raw)
          method = payload.get("method")
          if method == "initialize":
              print(json.dumps({"jsonrpc":"2.0","id":payload["id"],"result":{"ok":True}}), flush=True)
          elif method == "thread/start":
              print(json.dumps({"jsonrpc":"2.0","id":payload["id"],"result":{"thread":{"id":"thread-1"}}}), flush=True)
          elif method == "turn/start":
              print(json.dumps({"jsonrpc":"2.0","method":"turn/completed","params":{"turn":{"id":"turn-1","status":"completed"}}}), flush=True)
              break
      """
    )

    File.write!(
      codex_exec,
      """
      #!/bin/bash
      printf '%s\n' '{"type":"thread.started","thread_id":"thread_exec"}'
      printf '%s\n' '{"type":"turn.started"}'
      printf '%s\n' '{"type":"turn.completed"}'
      sleep 1
      """
    )

    File.write!(
      opencode,
      """
      #!/bin/bash
      printf '%s\n' '{"type":"session.created","sessionID":"session_cli"}'
      printf '%s\n' '{"type":"task.started"}'
      sleep 10
      """
    )

    File.write!(
      opencode_server,
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
      prompted = {"value": False}
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
                  self._send(200, [{"parts":[{"type":"text","text":"done"}],"info":{"role":"assistant","finish":"stop","tokens":{"input":1,"output":1,"total":2},"time":{"completed":1}}}] if prompted["value"] else [])
              elif path == "/session/status":
                  self._send(200, {"session-1":{"type":"running"}})
              else:
                  self._send(404, {"error":"missing"})
          def do_POST(self):
              path = urlparse(self.path).path
              if path == "/session":
                  self._send(200, {"id":"session-1"})
              elif path == "/session/session-1/prompt_async":
                  prompted["value"] = True
                  self.send_response(204); self.end_headers()
              elif path == "/global/dispose":
                  self.send_response(204); self.end_headers()
                  threading.Thread(target=httpd.shutdown, daemon=True).start()
              else:
                  self.send_response(204); self.end_headers()
          def log_message(self, format, *args):
              return
      httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
      httpd.serve_forever()
      """
    )

    for path <- [codex_app, codex_exec, opencode, opencode_server], do: File.chmod!(path, 0o755)

    File.write!(
      Path.join(workspace, ".git/symphony/plan.json"),
      Jason.encode!(%{
        "summary" => "Plan",
        "steps" => [%{"id" => "1", "content" => "Done", "status" => "completed"}]
      })
    )

    File.write!(
      Path.join(workspace, ".git/symphony/result.json"),
      Jason.encode!(%{
        "status" => "blocked",
        "summary" => "Blocked",
        "tests" => [],
        "artifacts" => [],
        "notes" => nil
      })
    )

    File.write!(
      Path.join(workspace, ".git/symphony/demo-plan.json"),
      Jason.encode!(%{"url" => "http://127.0.0.1:3000"})
    )

    on_exit(fn -> File.rm_rf!(workspace) end)

    %{
      workspace: workspace,
      codex_app: codex_app,
      codex_exec: codex_exec,
      opencode: opencode,
      opencode_server: opencode_server
    }
  end

  test "dispatches supported backends", ctx do
    base = %Symphony.Config{
      turn_timeout_ms: 5_000,
      read_timeout_ms: 100,
      stall_timeout_ms: 5_000,
      codex_router_default_provider: "default",
      codex_model: "gpt-5",
      codex_model_provider: "openai",
      codex_profiles: %{},
      openai_api_key: nil,
      zai_api_key: nil,
      openai_base_url: nil
    }

    assert {:ok, _} =
             Runner.run_turn(
               ctx.workspace,
               %{
                 base
                 | codex_command: ctx.codex_app,
                   codex_profiles: %{"default" => %{backend: "codex_app_server"}}
               },
               nil,
               1,
               "prompt",
               %{provider: "default", model: "gpt-5"},
               fn _ -> :ok end
             )

    assert {:ok, _} =
             Runner.run_turn(
               ctx.workspace,
               %{
                 base
                 | codex_command: ctx.codex_exec,
                   codex_profiles: %{"default" => %{backend: "codex_exec"}}
               },
               nil,
               1,
               "prompt",
               %{provider: "default", model: "gpt-5"},
               fn _ -> :ok end
             )

    assert {:ok, _} =
             Runner.run_turn(
               ctx.workspace,
               %{
                 base
                 | codex_command: ctx.opencode,
                   codex_profiles: %{"default" => %{backend: "opencode"}}
               },
               nil,
               1,
               "prompt",
               %{provider: "default", model: "gpt-5"},
               fn _ -> :ok end
             )

    assert {:ok, _} =
             Runner.run_turn(
               ctx.workspace,
               %{
                 base
                 | codex_command: ctx.opencode_server,
                   codex_profiles: %{"default" => %{backend: "opencode_server"}}
               },
               %Symphony.Issue{identifier: "TEST-1", title: "Issue"},
               1,
               "prompt",
               %{provider: "default", model: "gpt-5"},
               fn _ -> :ok end
             )
  end

  test "lists supported backends" do
    assert Runner.supported_backends() == [
             "codex_app_server",
             "codex_exec",
             "opencode",
             "opencode_server"
           ]
  end

  test "falls back from codex app-server to default provider when account/model is unsupported",
       ctx do
    codex_fail = Path.join(ctx.workspace, "fake-codex-fail")
    fallback_cmd = Path.join(ctx.workspace, "fake-opencode-fallback")

    File.write!(
      codex_fail,
      """
      #!/usr/bin/env python3
      import json, sys
      for raw in sys.stdin:
          payload = json.loads(raw)
          method = payload.get("method")
          if method == "initialize":
              print(json.dumps({"jsonrpc":"2.0","id":payload["id"],"result":{"ok":True}}), flush=True)
          elif method == "thread/start":
              print(json.dumps({"jsonrpc":"2.0","id":payload["id"],"result":{"thread":{"id":"thread-1"}}}), flush=True)
          elif method == "turn/start":
              print(json.dumps({"jsonrpc":"2.0","id":payload["id"],"error":{"message":"This model is not supported when using Codex with a ChatGPT account"}}), flush=True)
              break
      """
    )

    File.write!(
      fallback_cmd,
      """
      #!/bin/bash
      printf '%s\n' '{"type":"session.created","sessionID":"session_cli"}'
      printf '%s\n' '{"type":"step_finish","step":{"finishReason":"stop"}}'
      """
    )

    for path <- [codex_fail, fallback_cmd], do: File.chmod!(path, 0o755)

    config = %Symphony.Config{
      turn_timeout_ms: 5_000,
      read_timeout_ms: 100,
      stall_timeout_ms: 5_000,
      codex_command: codex_fail,
      codex_router_default_provider: "fallback",
      codex_model: "gpt-5",
      codex_model_provider: "openai",
      codex_reasoning_effort: "medium",
      codex_profiles: %{
        "openai" => %{backend: "codex_app_server", command: codex_fail},
        "fallback" => %{backend: "opencode", command: fallback_cmd, model: "GLM-5"}
      }
    }

    updates = capture_updates(fn ->
      assert {:ok, %{session_id: "session_cli"}} =
               Runner.run_turn(
                 ctx.workspace,
                 config,
                 nil,
                 1,
                 "prompt",
                 %{provider: "openai", model: "gpt-5"},
                 &send(self(), {:runner_update, &1})
               )
    end)

    assert Enum.any?(updates, fn
             %{type: :routing, routing: routing} ->
               routing[:provider] == "fallback" and
                 routing[:fallback_from_backend] == "codex_app_server" and
                 routing[:reason] == "fallback_from_unsupported_codex_account"

             _ ->
               false
           end)
  end

  test "falls back from opencode cli to opencode server on unstable cli failure", ctx do
    dual_dir = Path.join(ctx.workspace, "opencode-dual-bin")
    File.mkdir_p!(dual_dir)
    dual = Path.join(dual_dir, "opencode")

    File.write!(
      dual,
      """
      #!/usr/bin/env python3
      import json, sys, threading, time
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
      from urllib.parse import urlparse

      args = sys.argv[1:]
      if len(args) > 0 and args[0] == "serve":
          port = 4096
          for i, arg in enumerate(args):
              if arg == "--port" and i + 1 < len(args):
                  port = int(args[i + 1])
          prompted = {"value": False}

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
                      payload = [{"parts":[{"type":"text","text":"done"}],"info":{"role":"assistant","finish":"stop","tokens":{"input":1,"output":1,"total":2},"time":{"completed":1}}}] if prompted["value"] else []
                      self._send(200, payload)
                  elif path == "/session/status":
                      self._send(200, {"session-1":{"type":"running"}})
                  else:
                      self._send(404, {"error":"missing"})

              def do_POST(self):
                  path = urlparse(self.path).path
                  if path == "/session":
                      self._send(200, {"id":"session-1"})
                  elif path == "/session/session-1/prompt_async":
                      prompted["value"] = True
                      self.send_response(204)
                      self.end_headers()
                  elif path == "/global/dispose":
                      self.send_response(204)
                      self.end_headers()
                      threading.Thread(target=httpd.shutdown, daemon=True).start()
                  else:
                      self.send_response(204)
                      self.end_headers()

              def log_message(self, format, *args):
                  return

          httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
          httpd.serve_forever()
      else:
          sys.exit(17)
      """
    )

    File.chmod!(dual, 0o755)

    config = %Symphony.Config{
      turn_timeout_ms: 5_000,
      read_timeout_ms: 100,
      stall_timeout_ms: 5_000,
      codex_command: dual,
      codex_router_default_provider: "default",
      codex_model: "gpt-5",
      codex_model_provider: "openai",
      codex_profiles: %{"default" => %{backend: "opencode", command: dual}}
    }

    updates = capture_updates(fn ->
      assert {:ok, %{session_id: "session-1"}} =
               Runner.run_turn(
                 ctx.workspace,
                 config,
                 %Symphony.Issue{identifier: "TEST-1", title: "Issue"},
                 1,
                 "prompt",
                 %{provider: "default", model: "gpt-5"},
                 &send(self(), {:runner_update, &1})
               )
    end)

    assert Enum.any?(updates, fn
             %{type: :routing, routing: routing} ->
               routing[:fallback_from_backend] == "opencode" and
                 routing[:reason] == "fallback_from_opencode_cli"

             _ ->
               false
           end)
  end

  test "falls back from opencode server to opencode cli on server session error", ctx do
    dual_dir = Path.join(ctx.workspace, "opencode-reverse-bin")
    File.mkdir_p!(dual_dir)
    dual = Path.join(dual_dir, "opencode")

    File.write!(
      dual,
      """
      #!/usr/bin/env python3
      import json, sys, threading
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
      from urllib.parse import urlparse

      args = sys.argv[1:]
      if len(args) > 0 and args[0] == "serve":
          port = 4096
          for i, arg in enumerate(args):
              if arg == "--port" and i + 1 < len(args):
                  port = int(args[i + 1])

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
                      self._send(200, [])
                  elif path == "/session/status":
                      self._send(200, {"session-1":{"type":"error"}})
                  else:
                      self._send(404, {"error":"missing"})

              def do_POST(self):
                  path = urlparse(self.path).path
                  if path == "/session":
                      self._send(200, {"id":"session-1"})
                  elif path == "/session/session-1/prompt_async":
                      self.send_response(204)
                      self.end_headers()
                  elif path == "/global/dispose":
                      self.send_response(204)
                      self.end_headers()
                      threading.Thread(target=httpd.shutdown, daemon=True).start()
                  else:
                      self.send_response(204)
                      self.end_headers()

              def log_message(self, format, *args):
                  return

          httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
          httpd.serve_forever()
      else:
          print(json.dumps({"type":"session.created","sessionID":"session_cli"}), flush=True)
          print(json.dumps({"type":"step_finish","step":{"finishReason":"stop"}}), flush=True)
      """
    )

    File.chmod!(dual, 0o755)

    config = %Symphony.Config{
      turn_timeout_ms: 5_000,
      read_timeout_ms: 100,
      stall_timeout_ms: 5_000,
      codex_command: dual,
      codex_router_default_provider: "default",
      codex_model: "gpt-5",
      codex_model_provider: "openai",
      codex_profiles: %{"default" => %{backend: "opencode_server", command: dual}}
    }

    updates = capture_updates(fn ->
      assert {:ok, %{session_id: "session_cli"}} =
               Runner.run_turn(
                 ctx.workspace,
                 config,
                 %Symphony.Issue{identifier: "TEST-1", title: "Issue"},
                 1,
                 "prompt",
                 %{provider: "default", model: "gpt-5"},
                 &send(self(), {:runner_update, &1})
               )
    end)

    assert Enum.any?(updates, fn
             %{type: :routing, routing: routing} ->
               routing[:fallback_from_backend] == "opencode_server" and
                 routing[:reason] == "fallback_from_opencode_server"

             _ ->
               false
           end)
  end

  defp capture_updates(fun) do
    parent = self()
    ref = make_ref()
    fun.()
    send(parent, {:runner_update_done, ref})

    collect_updates(ref, [])
  end

  defp collect_updates(ref, acc) do
    receive do
      {:runner_update, update} ->
        collect_updates(ref, [update | acc])

      {:runner_update_done, ^ref} ->
        Enum.reverse(acc)
    after
      100 ->
        Enum.reverse(acc)
    end
  end
end
