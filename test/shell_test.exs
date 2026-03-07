defmodule Symphony.ShellTest do
  use ExUnit.Case, async: true

  test "managed script can be started and stopped" do
    tmp_dir = Path.join(System.tmp_dir!(), "symphony-shell-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    script = """
    while true; do
      echo alive
      sleep 1
    done
    """

    assert {:ok, handle} = Symphony.Shell.start_managed_script(script, tmp_dir, 2_000)
    assert is_integer(handle.pid)

    Process.sleep(250)
    assert Process.alive?(self())
    assert File.exists?(handle.log_path)

    assert :ok = Symphony.Shell.stop_managed_script(handle, 2_000)
    refute File.exists?(handle.script_path)
  end
end
