defmodule Symphony.ConfigValidationTest do
  use ExUnit.Case, async: true

  test "validate_dispatch rejects unsupported codex backends" do
    config = %Symphony.Config{
      tracker_kind: "mock",
      tracker_mock_file: "test/support/mock_issues.json",
      max_concurrent_agents: 1,
      poll_interval_ms: 1_000,
      codex_command: "codex",
      codex_profiles: %{"bad" => %{backend: "nope"}}
    }

    assert {:error, :unsupported_codex_backend} = Symphony.Config.validate_dispatch(config)
  end

  test "validate_dispatch rejects missing mock tracker file" do
    config = %Symphony.Config{
      tracker_kind: "mock",
      tracker_mock_file: nil,
      max_concurrent_agents: 1,
      poll_interval_ms: 1_000,
      codex_command: "codex",
      codex_profiles: %{}
    }

    assert {:error, :tracker_mock_file_missing} = Symphony.Config.validate_dispatch(config)
  end

  test "validate_dispatch accepts a minimal mock configuration" do
    config = %Symphony.Config{
      tracker_kind: "mock",
      tracker_mock_file: "test/support/mock_issues.json",
      max_concurrent_agents: 1,
      poll_interval_ms: 1_000,
      codex_command: "codex",
      codex_profiles: %{}
    }

    assert :ok = Symphony.Config.validate_dispatch(config)
  end
end
