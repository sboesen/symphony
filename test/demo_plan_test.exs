defmodule Symphony.DemoPlanTest do
  use ExUnit.Case, async: true

  setup do
    workspace = Path.join(System.tmp_dir!(), "symphony-demo-plan-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(workspace, ".git/symphony"))

    on_exit(fn ->
      File.rm_rf!(workspace)
    end)

    %{path: Path.join(workspace, ".git/symphony/demo-plan.json")}
  end

  test "strips screenshot assertions entirely", %{path: path} do
    File.write!(
      path,
      Jason.encode!(%{
        "capture" => "screenshot",
        "url" => "http://localhost:4321/",
        "assertions" => [
          %{"type" => "selector_visible", "selector" => ".hero"},
          %{"type" => "text_present", "value" => "Guide"}
        ]
      })
    )

    assert {:ok, plan} = Symphony.DemoPlan.load_and_sanitize(path)
    assert plan["capture"] == "screenshot"
    assert plan["assertions"] == []
  end

  test "caps video assertions to simple visible checks", %{path: path} do
    File.write!(
      path,
      Jason.encode!(%{
        "capture" => "video",
        "url" => "http://localhost:4321/",
        "assertions" => [
          %{"type" => "selector_visible", "selector" => ".hero"},
          %{"type" => "selector_hidden", "selector" => ".old-links"},
          %{"type" => "console_errors_absent"},
          %{"type" => "text_present", "value" => "Guide"}
        ]
      })
    )

    assert {:ok, plan} = Symphony.DemoPlan.load_and_sanitize(path)

    assert plan["assertions"] == [
             %{"type" => "selector_visible", "selector" => ".hero"},
             %{"type" => "selector_hidden", "selector" => ".old-links"}
           ]
  end
end
