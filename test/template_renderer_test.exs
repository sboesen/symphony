defmodule Symphony.TemplateRendererTest do
  use ExUnit.Case, async: true

  alias Symphony.TemplateRenderer

  test "renders default prompt for blank templates" do
    issue = %Symphony.Issue{identifier: "TEST-1"}

    assert {:ok, "You are working on an issue from Linear."} =
             TemplateRenderer.render("   ", issue, 1)
  end

  test "renders attempt and nested issue fields" do
    issue = %Symphony.Issue{
      identifier: "TEST-1",
      title: "Ship it",
      labels: ["bug"],
      created_at: ~U[2026-03-10 00:00:00Z]
    }

    assert {:ok, rendered} =
             TemplateRenderer.render(
               "Attempt {{ attempt }} for {{ issue.identifier }}: {{ issue.title }} {{ issue.labels }} {{ issue.created_at }}",
               issue,
               3
             )

    assert rendered =~ "Attempt 3 for TEST-1: Ship it"
    assert rendered =~ ~s(["bug"])
    assert rendered =~ "2026-03-10T00:00:00Z"
  end

  test "renders full issue struct for issue token" do
    issue = %Symphony.Issue{identifier: "TEST-1", title: "Ship it"}

    assert {:ok, rendered} = TemplateRenderer.render("Issue: {{ issue }}", issue, 1)
    assert rendered =~ "identifier: \"TEST-1\""
    assert rendered =~ "title: \"Ship it\""
  end

  test "rejects unknown variables and filters" do
    issue = %Symphony.Issue{identifier: "TEST-1"}

    assert {:error, :template_render_error} =
             TemplateRenderer.render("{{ missing }}", issue, 1)

    assert {:error, :template_render_error} =
             TemplateRenderer.render("{{ issue.identifier | upcase }}", issue, 1)
  end

  test "rejects missing nested issue fields" do
    issue = %Symphony.Issue{identifier: "TEST-1"}

    assert {:error, :template_render_error} =
             TemplateRenderer.render("{{ issue.missing_field }}", issue, 1)
  end
end
