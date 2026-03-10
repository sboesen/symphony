defmodule Symphony.LoggerTest do
  use ExUnit.Case, async: true

  test "truncate returns binaries unchanged when short enough" do
    assert Symphony.Logger.truncate("short") == "short"
  end

  test "truncate inspects non-binary values" do
    assert Symphony.Logger.truncate(%{ok: true}) == "%{ok: true}"
  end

  test "logging helpers return ok" do
    assert :ok = Symphony.Logger.info("info event")
    assert :ok = Symphony.Logger.warn("warn event")
    assert :ok = Symphony.Logger.error("error event")
    assert :ok = Symphony.Logger.debug("debug event")
  end
end
