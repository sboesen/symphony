defmodule Symphony.WorkflowTest do
  use ExUnit.Case, async: true

  test "load parses front matter and prompt body" do
    path = write_temp!("""
    ---
    tracker:
      kind: mock
    ---
    Ship the thing.
    """)

    on_exit(fn -> File.rm(path) end)

    assert {:ok, workflow} = Symphony.Workflow.load(path)
    assert workflow.config["tracker"]["kind"] == "mock"
    assert workflow.prompt_template == "Ship the thing."
    assert is_integer(workflow.mtime_ms)
  end

  test "load supports prompt-only workflows" do
    path = write_temp!("Just do the work.")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, workflow} = Symphony.Workflow.load(path)
    assert workflow.config == %{}
    assert workflow.prompt_template == "Just do the work."
  end

  test "load rejects malformed front matter" do
    path = write_temp!("---\ntracker: [\n---\nOops")
    on_exit(fn -> File.rm(path) end)

    assert {:error, :workflow_parse_error} = Symphony.Workflow.load(path)
  end

  defp write_temp!(content) do
    path = Path.join(System.tmp_dir!(), "workflow-test-#{System.unique_integer([:positive])}.md")
    File.write!(path, content)
    path
  end
end
