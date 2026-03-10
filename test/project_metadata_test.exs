defmodule Symphony.ProjectMetadataTest do
  use ExUnit.Case, async: true

  test "parses repo url from human-readable repo line" do
    description = """
    Blog automation project.

    Repo: git@github.com:sboesen/blog.boesen.me.git
    """

    assert %{repo_url: "git@github.com:sboesen/blog.boesen.me.git"} =
             Symphony.ProjectMetadata.parse(description)
  end

  test "parses repo url from hidden metadata marker for backward compatibility" do
    description = """
    Blog automation project.

    <!-- symphony-project-config {"repo_url":"git@github.com:sboesen/blog.boesen.me.git"} -->
    """

    assert %{repo_url: "git@github.com:sboesen/blog.boesen.me.git"} =
             Symphony.ProjectMetadata.parse(description)
  end

  test "upsert_repo appends repo line when missing" do
    updated =
      Symphony.ProjectMetadata.upsert_repo(
        "Blog automation project.",
        "git@github.com:sboesen/blog.boesen.me.git"
      )

    assert String.contains?(updated, Symphony.ProjectMetadata.repo_prefix())
    assert String.contains?(updated, "git@github.com:sboesen/blog.boesen.me.git")
  end

  test "upsert_repo replaces existing repo line" do
    description = """
    Blog automation project.

    Repo: git@github.com:sboesen/old.git
    """

    updated =
      Symphony.ProjectMetadata.upsert_repo(
        description,
        "git@github.com:sboesen/blog.boesen.me.git"
      )

    refute String.contains?(updated, "git@github.com:sboesen/old.git")
    assert String.contains?(updated, "git@github.com:sboesen/blog.boesen.me.git")
  end

  test "upsert_repo migrates hidden metadata marker to repo line" do
    description = """
    Blog automation project.

    <!-- symphony-project-config {"repo_url":"git@github.com:sboesen/old.git"} -->
    """

    updated =
      Symphony.ProjectMetadata.upsert_repo(
        description,
        "git@github.com:sboesen/blog.boesen.me.git"
      )

    refute String.contains?(updated, "<!-- symphony-project-config")
    assert String.contains?(updated, "Repo: git@github.com:sboesen/blog.boesen.me.git")
  end
end
