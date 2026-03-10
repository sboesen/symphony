defmodule Symphony.PlanContractTest do
  use ExUnit.Case, async: true

  setup do
    workspace = Path.join(System.tmp_dir!(), "symphony-plan-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(workspace, ".git/symphony"))

    on_exit(fn ->
      File.rm_rf!(workspace)
    end)

    %{workspace: workspace}
  end

  test "loads a valid nested plan and renders a workpad", %{workspace: workspace} do
    File.write!(
      Path.join(workspace, ".git/symphony/plan.json"),
      Jason.encode!(%{
        "summary" => "Ship the feature safely",
        "targets" => %{
          "routes" => ["/posts"],
          "files" => ["src/pages/posts.astro"],
          "surface" => "Posts page intro links"
        },
        "steps" => [
          %{
            "id" => "1",
            "content" => "Inspect the current implementation",
            "status" => "completed",
            "children" => [
              %{"id" => "1.1", "content" => "Locate the view", "status" => "completed"}
            ]
          },
          %{"id" => "2", "content" => "Implement the change", "status" => "completed"}
        ]
      })
    )

    assert {:ok, plan} = Symphony.PlanContract.load(workspace)
    assert Symphony.PlanContract.all_done?(plan)

    rendered = Symphony.PlanContract.render_workpad(plan)
    assert rendered =~ "## Plan"
    assert rendered =~ "- Routes: /posts"
    assert rendered =~ "- Files: src/pages/posts.astro"
    assert rendered =~ "- [x] Inspect the current implementation"
    assert rendered =~ "  - [x] Locate the view"
    assert rendered =~ "[Symphony:plan]"
    assert rendered =~ "_Maintained by Symphony._"
  end

  test "rejects invalid step statuses", %{workspace: workspace} do
    File.write!(
      Path.join(workspace, ".git/symphony/plan.json"),
      Jason.encode!(%{
        "steps" => [
          %{"content" => "Do the thing", "status" => "maybe"}
        ]
      })
    )

    assert {:error, :invalid} = Symphony.PlanContract.load(workspace)
  end

  test "can mark an existing plan fully completed", %{workspace: workspace} do
    File.write!(
      Path.join(workspace, ".git/symphony/plan.json"),
      Jason.encode!(%{
        "summary" => "Ship it",
        "targets" => %{
          "routes" => ["/"],
          "files" => ["src/pages/index.astro"],
          "surface" => "Homepage intro links"
        },
        "steps" => [
          %{
            "id" => "1",
            "content" => "Do the thing",
            "status" => "pending",
            "children" => [
              %{"id" => "1.1", "content" => "Sub-step", "status" => "in_progress"}
            ]
          }
        ]
      })
    )

    assert {:ok, plan} = Symphony.PlanContract.load(workspace)
    completed = Symphony.PlanContract.mark_all_completed(plan)
    assert Symphony.PlanContract.all_done?(completed)
    assert Symphony.PlanContract.render_workpad(completed) =~ "- [x] Do the thing"
    assert Symphony.PlanContract.render_workpad(completed) =~ "  - [x] Sub-step"
  end

  test "accepts a generic non-ui plan without explicit targets", %{workspace: workspace} do
    File.write!(
      Path.join(workspace, ".git/symphony/plan.json"),
      Jason.encode!(%{
        "summary" => "Write the essay about lessons learned from implementing Symphony",
        "steps" => [
          %{"content" => "Review the existing notes and source material", "status" => "pending"},
          %{"content" => "Draft the essay with concrete examples", "status" => "pending"},
          %{"content" => "Revise for clarity and publish", "status" => "pending"}
        ]
      })
    )

    assert {:ok, _plan} = Symphony.PlanContract.load(workspace)
  end

  test "renders planning placeholder with Symphony plan marker" do
    rendered = Symphony.PlanContract.render_planning_placeholder("Remove the Help link")

    assert rendered =~ "## Plan"
    assert rendered =~ "Planning in progress..."
    assert rendered =~ "[Symphony:plan]"
    assert rendered =~ "_Maintained by Symphony._"
  end
end
