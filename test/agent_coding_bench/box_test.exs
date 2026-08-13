defmodule AgentCodingBench.BoxTest do
  use ExUnit.Case, async: false

  alias AgentCodingBench.Box

  @moduletag :tmp_dir

  test "exec runs a command on the configured ssh host", %{tmp_dir: tmp_dir} do
    ssh_path = Path.join(tmp_dir, "ssh")

    File.write!(ssh_path, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n")
    File.chmod!(ssh_path, 0o755)

    original_path = System.get_env("PATH")
    System.put_env("PATH", tmp_dir <> ":" <> original_path)
    on_exit(fn -> System.put_env("PATH", original_path) end)

    assert Box.exec("git status", host: "bench-box") ==
             {"bench-box\ngit status\n", 0}
  end
end
