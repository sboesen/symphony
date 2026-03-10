defmodule Symphony.OpenCodeRuntimeTest do
  use ExUnit.Case, async: true

  test "build_env isolates opencode from global config and disables MCPs" do
    workspace =
      Path.join(System.tmp_dir!(), "symphony-open-code-runtime-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    env =
      Symphony.OpenCodeRuntime.build_env(workspace, %{"EXISTING" => "1"}, %{
        model: "zai-coding-plan/glm-5"
      })

    assert env["EXISTING"] == "1"
    assert String.ends_with?(env["XDG_CONFIG_HOME"], ".symphony-opencode")
    assert File.dir?(Path.join(env["XDG_CONFIG_HOME"], "opencode"))

    config = Jason.decode!(env["OPENCODE_CONFIG_CONTENT"])
    assert config["mcp"] == %{}
    assert config["model"] == "zai-coding-plan/glm-5"
    assert config["permission"]["edit"] == "allow"
    assert config["permission"]["bash"] == "allow"
    assert config["permission"]["webfetch"] == "allow"
  end
end
