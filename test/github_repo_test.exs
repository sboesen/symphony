defmodule Symphony.GitHubRepoTest do
  use ExUnit.Case, async: true

  test "normalizes https github urls to ssh" do
    assert {:ok, "git@github.com:sboesen/blog.boesen.me.git"} =
             Symphony.GitHubRepo.normalize_to_ssh("https://github.com/sboesen/blog.boesen.me")
  end

  test "normalizes ssh github urls with missing suffix" do
    assert {:ok, "git@github.com:sboesen/blog.boesen.me.git"} =
             Symphony.GitHubRepo.normalize_to_ssh("git@github.com:sboesen/blog.boesen.me")
  end

  test "extracts repo slug from normalized ssh url" do
    assert {:ok, "sboesen/blog.boesen.me"} =
             Symphony.GitHubRepo.slug_from_ssh("git@github.com:sboesen/blog.boesen.me.git")
  end
end
