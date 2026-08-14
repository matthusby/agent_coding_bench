defmodule AgentCodingBench.ProvisionBoxTest do
  use ExUnit.Case, async: true

  @helper Path.expand("../../bin/provision-box", __DIR__)

  test "provisions a box and idempotently updates the managed SSH config" do
    root = temp_dir!()
    ssh_config = Path.join(root, "ssh_config")
    command_log = Path.join(root, "commands.log")
    fake_bin = Path.join(root, "bin")

    File.mkdir_p!(fake_bin)
    File.write!(ssh_config, "Host github.com\n  User git\n")
    install_fake_commands!(fake_bin)

    env = [
      {"PATH", fake_bin <> ":" <> System.fetch_env!("PATH")},
      {"SSH_CONFIG_FILE", ssh_config},
      {"PROVISION_COMMAND_LOG", command_log}
    ]

    assert {_output, 0} = System.cmd("bash", [@helper, "203.0.113.42"], env: env)
    assert {_output, 0} = System.cmd("bash", [@helper, "203.0.113.43"], env: env)

    config = File.read!(ssh_config)

    assert config =~ "Host github.com\n  User git"
    assert config =~ "Host box"
    assert config =~ "HostName 203.0.113.43"
    assert config =~ "LocalForward 8000 127.0.0.1:8000"
    assert config =~ "LocalForward 4096 127.0.0.1:4096"
    assert config =~ "StrictHostKeyChecking accept-new"
    assert length(Regex.scan(~r/# BEGIN agent_coding_bench box/, config)) == 1

    commands = File.read!(command_log)

    assert commands =~ "ssh-keygen -R 203.0.113.43"
    provisioner = @helper |> Path.dirname() |> Path.join("../box/provision.sh") |> Path.expand()

    assert commands =~
             "scp -F #{ssh_config} -o ClearAllForwardings=yes -o ControlMaster=no -o ControlPath=none #{provisioner} box:/root/agent-coding-bench-provision.sh"

    assert commands =~
             "ssh -F #{ssh_config} -o ClearAllForwardings=yes -o ControlMaster=no -o ControlPath=none box bash /root/agent-coding-bench-provision.sh"

    assert commands =~ "-fN -o ExitOnForwardFailure=yes box"
    assert commands =~ "curl --fail --silent --show-error http://127.0.0.1:8000/metrics"
    assert commands =~ "curl --fail --silent --show-error http://127.0.0.1:4096/doc"
  end

  test "rejects anything other than an IPv4 address" do
    root = temp_dir!()
    ssh_config = Path.join(root, "ssh_config")

    assert {output, status} =
             System.cmd("bash", [@helper, "box.example.com"],
               env: [{"SSH_CONFIG_FILE", ssh_config}],
               stderr_to_stdout: true
             )

    assert status != 0
    assert output =~ "IPv4"
    refute File.exists?(ssh_config)
  end

  defp install_fake_commands!(directory) do
    script = """
    #!/usr/bin/env bash
    set -u

    command_name="$(basename "$0")"
    printf '%s %s\n' "$command_name" "$*" >> "$PROVISION_COMMAND_LOG"

    case "$command_name" in
      ssh)
        if [[ " $* " == *" -O exit "* ]]; then
          exit 1
        fi
        ;;
      lsof)
        exit 1
        ;;
    esac
    """

    for command <- ~w(ssh scp ssh-keygen curl lsof) do
      path = Path.join(directory, command)
      File.write!(path, script)
      File.chmod!(path, 0o755)
    end
  end

  defp temp_dir! do
    path = Path.join(System.tmp_dir!(), "provision-box-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
