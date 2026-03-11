defmodule Symphony.ShellTest do
  use ExUnit.Case, async: true

  test "run_script handles success, failures, defaults, timeout, and truncation" do
    tmp_dir = Path.join(System.tmp_dir!(), "symphony-shell-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    assert {:ok, ""} = Symphony.Shell.run_script(nil, tmp_dir, 100)
    assert {:ok, ""} = Symphony.Shell.run_script(:not_a_script, tmp_dir, 100)
    assert {:ok, "hello\n"} = Symphony.Shell.run_script("printf 'hello\\n'", tmp_dir, 1_000)

    assert {:error, {:exit_status, 7, "bad"}} =
             Symphony.Shell.run_script("echo bad; exit 7", tmp_dir, 1_000)

    assert {:error, :timeout} = Symphony.Shell.run_script("sleep 1", tmp_dir, 100)
    assert Symphony.Shell.truncate("abcdef", 3) == "abc"
    assert Symphony.Shell.truncate("abc", 10) == "abc"
    assert Symphony.Shell.truncate(123, 10) == 123
  end

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

  test "managed script defaults and invalid handles are no-ops" do
    tmp_dir = Path.join(System.tmp_dir!(), "symphony-shell-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    assert {:ok, nil} = Symphony.Shell.start_managed_script(nil, tmp_dir, 100)
    assert {:ok, nil} = Symphony.Shell.start_managed_script(:invalid, tmp_dir, 100)
    assert :ok = Symphony.Shell.stop_managed_script(nil, 100)
    assert :ok = Symphony.Shell.stop_managed_script(%{pid: -1}, 100)
  end
end
