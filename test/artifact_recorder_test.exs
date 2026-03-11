defmodule Symphony.ArtifactRecorderTest do
  use ExUnit.Case, async: false

  alias Symphony.ArtifactRecorder

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-artifact-recorder-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    bin_dir = Path.join(workspace, "bin")
    File.mkdir_p!(bin_dir)
    node_path = Path.join(bin_dir, "node")
    npm_path = Path.join(bin_dir, "npm")
    original_path = System.get_env("PATH") || ""

    File.write!(
      node_path,
      """
      #!/bin/bash
      output_dir=""
      mode="${FAKE_NODE_MODE:-success}"
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "--output-dir" ]; then
          output_dir="$2"
          shift 2
        else
          shift
        fi
      done

      mkdir -p "$output_dir"

      if [ "$mode" = "success" ]; then
        cat > "$output_dir/manifest.json" <<'EOF'
      {"capture_type":"video","status":"ready","source_url":"file:///demo.html","output_dir":"OUT","video_path":"OUT/demo.webm","raw_video_path":"OUT/raw.webm","trace_path":"OUT/trace.zip","screenshot_path":"OUT/final.png","verification_path":"OUT/verify.json","assertions":[{"type":"url_includes","value":"/demo"}],"verification":{"ok":true},"console_errors":[]}
      EOF
        sed -i.bak "s|OUT|$output_dir|g" "$output_dir/manifest.json" 2>/dev/null || python3 - "$output_dir/manifest.json" "$output_dir" <<'PY'
      import pathlib, sys
      path = pathlib.Path(sys.argv[1])
      text = path.read_text()
      path.write_text(text.replace("OUT", sys.argv[2]))
      PY
        exit 0
      elif [ "$mode" = "bad-manifest" ]; then
        echo "{" > "$output_dir/manifest.json"
        exit 0
      else
        exit 1
      fi
      """
    )

    File.write!(
      npm_path,
      """
      #!/bin/bash
      if [ "$1" = "install" ]; then
        mkdir -p "$PWD/node_modules"
        exit 0
      fi

      if [ "$1" = "run" ] && [ "$2" = "dev" ]; then
        shift 2
        host="127.0.0.1"
        port=""

        while [ "$#" -gt 0 ]; do
          case "$1" in
            --host)
              host="$2"
              shift 2
              ;;
            --port)
              port="$2"
              shift 2
              ;;
            *)
              shift
              ;;
          esac
        done

        printf "%s\\n" "$0 run dev --host $host --port $port $*" > "$PWD/npm_run_args.txt"
        exec python3 -m http.server "$port" --bind "$host"
      fi

      exit 0
      """
    )

    File.chmod!(node_path, 0o755)
    File.chmod!(npm_path, 0o755)
    System.put_env("PATH", bin_dir <> ":" <> original_path)

    html_path = Path.join(workspace, "demo.html")
    File.write!(html_path, "<html><body>demo</body></html>")

    on_exit(fn ->
      System.put_env("PATH", original_path)
      File.rm_rf!(workspace)
      System.delete_env("FAKE_NODE_MODE")
    end)

    %{workspace: workspace, html_path: html_path}
  end

  test "returns ready demo artifact from manifest", %{workspace: workspace, html_path: html_path} do
    System.put_env("FAKE_NODE_MODE", "success")

    config = %Symphony.Config{
      recording_enabled: true,
      recording_url: html_path,
      recording_ready_timeout_ms: 1_000,
      recording_wait_ms: 0,
      recording_width: 1280,
      recording_height: 720,
      recording_trace: false,
      hooks_timeout_ms: 1_000
    }

    issue = %Symphony.Issue{identifier: "TEST-1", title: "Artifact"}

    assert {:ok, [artifact]} = ArtifactRecorder.capture(issue, 1, workspace, config)
    assert artifact.kind == "demo_artifact"
    assert artifact.status == "ready"
    assert artifact.capture_type == "video"
    assert artifact.verification == %{"ok" => true}
  end

  test "returns no artifacts when recording is disabled", %{workspace: workspace} do
    config = %Symphony.Config{recording_enabled: false, recording_url: "demo.html"}
    issue = %Symphony.Issue{identifier: "TEST-1", title: "Artifact"}

    assert {:ok, []} = ArtifactRecorder.capture(issue, 1, workspace, config)
  end

  test "returns no artifacts when recording url is missing", %{workspace: workspace} do
    config = %Symphony.Config{recording_enabled: true, recording_url: nil}
    issue = %Symphony.Issue{identifier: "TEST-1", title: "Artifact"}

    assert {:ok, []} = ArtifactRecorder.capture(issue, 1, workspace, config)
  end

  test "requires a setup command for local http targets", %{workspace: workspace} do
    config = %Symphony.Config{
      recording_enabled: true,
      recording_url: "http://127.0.0.1:4567",
      recording_ready_timeout_ms: 1_000,
      recording_wait_ms: 0,
      recording_width: 1280,
      recording_height: 720,
      recording_trace: false,
      hooks_timeout_ms: 1_000
    }

    issue = %Symphony.Issue{identifier: "TEST-1", title: "Artifact"}

    assert {:error, :recording_setup_command_missing, []} =
             ArtifactRecorder.capture(issue, 1, workspace, config)
  end

  test "returns output dir errors when configured output base is invalid", %{
    workspace: workspace,
    html_path: html_path
  } do
    invalid_base = Path.join(workspace, "not-a-directory")
    File.write!(invalid_base, "file")

    config = %Symphony.Config{
      recording_enabled: true,
      recording_url: html_path,
      recording_output_dir: invalid_base,
      recording_ready_timeout_ms: 1_000,
      recording_wait_ms: 0,
      recording_width: 1280,
      recording_height: 720,
      recording_trace: false,
      hooks_timeout_ms: 1_000
    }

    issue = %Symphony.Issue{identifier: "TEST-1", title: "Artifact"}

    assert {:error, {:recording_output_dir_failed, _reason}} =
             ArtifactRecorder.capture(issue, 1, workspace, config)
  end

  test "returns failed artifact when manifest is malformed", %{
    workspace: workspace,
    html_path: html_path
  } do
    System.put_env("FAKE_NODE_MODE", "bad-manifest")

    config = %Symphony.Config{
      recording_enabled: true,
      recording_url: html_path,
      recording_ready_timeout_ms: 1_000,
      recording_wait_ms: 0,
      recording_width: 1280,
      recording_height: 720,
      recording_trace: false,
      hooks_timeout_ms: 1_000
    }

    issue = %Symphony.Issue{identifier: "TEST-1", title: "Artifact"}

    assert {:error, {:recording_capture_failed, _reason}, [artifact]} =
             ArtifactRecorder.capture(issue, 1, workspace, config)

    assert artifact.kind == "demo_artifact"
    assert artifact.status == "error"
  end

  test "returns failed artifact when capture command exits nonzero without a manifest", %{
    workspace: workspace,
    html_path: html_path
  } do
    System.put_env("FAKE_NODE_MODE", "fail")

    config = %Symphony.Config{
      recording_enabled: true,
      recording_url: html_path,
      recording_ready_timeout_ms: 1_000,
      recording_wait_ms: 0,
      recording_width: 1280,
      recording_height: 720,
      recording_trace: false,
      hooks_timeout_ms: 1_000
    }

    issue = %Symphony.Issue{identifier: "TEST-1", title: "Artifact"}

    assert {:error, {:recording_capture_failed, {:recording_command_failed, 1, ""}}, [artifact]} =
             ArtifactRecorder.capture(issue, 1, workspace, config)

    assert artifact.kind == "demo_artifact"
    assert artifact.status == "error"
    assert artifact.error =~ "recording_command_failed"
  end

  test "demo plan overrides trigger js dependency install and local port rebinding", %{
    workspace: workspace
  } do
    System.put_env("FAKE_NODE_MODE", "success")

    occupied_port = listen_on_ephemeral_port()

    demo_plan_dir = Path.join(workspace, ".git/symphony")
    File.mkdir_p!(demo_plan_dir)
    File.write!(Path.join(workspace, "package.json"), ~s({"name":"demo","scripts":{"dev":"vite"}}))

    File.write!(
      Path.join(demo_plan_dir, "demo-plan.json"),
      Jason.encode!(%{
        "url" => "http://127.0.0.1:#{occupied_port}/",
        "ready_url" => "http://127.0.0.1:#{occupied_port}/",
        "setup_command" => "npm run dev"
      })
    )

    config = %Symphony.Config{
      recording_enabled: true,
      recording_url: "ignored-by-plan",
      recording_ready_timeout_ms: 6_000,
      recording_wait_ms: 0,
      recording_width: 1280,
      recording_height: 720,
      recording_trace: false,
      hooks_timeout_ms: 2_000
    }

    issue = %Symphony.Issue{identifier: "TEST-1", title: "Artifact"}

    try do
      assert {:error, {:recording_capture_failed, :recording_ready_timeout}, [artifact]} =
               ArtifactRecorder.capture(issue, 1, workspace, config)

      assert artifact.status == "error"
      assert File.exists?(Path.join(workspace, "node_modules"))

      assert {:ok, args} = File.read(Path.join(workspace, "npm_run_args.txt"))
      assert args =~ "--host localhost"
      refute args =~ "--port #{occupied_port}"
    after
      close_listen_socket(occupied_port)
    end
  end

  defp listen_on_ephemeral_port do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, {:packet, 0}, {:active, false}, {:ip, {127, 0, 0, 1}}])

    {:ok, {_addr, port}} = :inet.sockname(socket)
    Process.put({__MODULE__, :occupied_socket, port}, socket)
    port
  end

  defp close_listen_socket(port) do
    case Process.delete({__MODULE__, :occupied_socket, port}) do
      socket when is_port(socket) -> :gen_tcp.close(socket)
      _ -> :ok
    end
  end
end
