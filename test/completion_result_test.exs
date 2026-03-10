defmodule Symphony.CompletionResultTest do
  use ExUnit.Case, async: true

  setup do
    workspace = Path.join(System.tmp_dir!(), "symphony-completion-result-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(workspace, ".git/symphony"))

    on_exit(fn ->
      File.rm_rf!(workspace)
    end)

    %{workspace: workspace}
  end

  test "loads a valid completion result", %{workspace: workspace} do
    File.write!(
      Path.join(workspace, ".git/symphony/result.json"),
      Jason.encode!(%{
        "status" => "completed",
        "summary" => "Finished the change",
        "tests" => ["mix test"],
        "artifacts" => ["artifact.txt"],
        "notes" => "ready"
      })
    )

    assert {:ok, result} = Symphony.CompletionResult.load(workspace)
    assert result.status == "completed"
    assert result.tests == ["mix test"]
    assert result.artifacts == ["artifact.txt"]
  end

  test "returns missing when the result file does not exist", %{workspace: workspace} do
    assert {:error, :missing} = Symphony.CompletionResult.load(workspace)
  end

  test "rejects invalid statuses", %{workspace: workspace} do
    File.write!(
      Path.join(workspace, ".git/symphony/result.json"),
      Jason.encode!(%{"status" => "maybe"})
    )

    assert {:error, :invalid} = Symphony.CompletionResult.load(workspace)
  end
end
