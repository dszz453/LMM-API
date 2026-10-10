"""通过 SSH 在 192.168.31.180 上执行命令（paramiko 实现，无需 sshpass）。

用法：
    python ssh_exec.py "docker ps"
    python ssh_exec.py            # 交互式读取 stdin 中的命令
"""

import sys

import paramiko

HOST = "192.168.31.180"
USER = "root"
PASSWORD = "Hik297360+"
PORT = 22


def run(cmd: str, timeout: int = 180) -> tuple[int, str, str]:
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(HOST, port=PORT, username=USER, password=PASSWORD,
                   timeout=15, banner_timeout=20, auth_timeout=20)
    try:
        stdin, stdout, stderr = client.exec_command(cmd, timeout=timeout)
        out = stdout.read().decode("utf-8", "replace")
        err = stderr.read().decode("utf-8", "replace")
        code = stdout.channel.recv_exit_status()
        return code, out, err
    finally:
        client.close()


def main() -> None:
    if len(sys.argv) > 1:
        cmd = " ".join(sys.argv[1:])
    else:
        cmd = sys.stdin.read()
    code, out, err = run(cmd)
    if out:
        sys.stdout.write(out)
    if err:
        sys.stderr.write(err)
    sys.exit(code)


if __name__ == "__main__":
    main()
