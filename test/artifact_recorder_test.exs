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

    File.chmod!(node_path, 0o755)
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
end
