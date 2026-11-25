"""Run the node deploy script over SSH (key authentication, pinned host keys)."""

from __future__ import annotations

import re
import secrets
import shlex
import socket
import time
from collections.abc import Callable
from importlib import resources
from pathlib import Path
from urllib.parse import urlparse

import paramiko

from .inventory import Node, Service

LineSink = Callable[[str], None]
Executor = Callable[[Node, str, float, LineSink], int]
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
MAX_UNTERMINATED_BYTES = 65536
# A new session makes the script its own process group, so a timeout can kill everything it started.
REMOTE_COMMAND = "if command -v setsid >/dev/null 2>&1; then exec setsid -w bash -s; else exec bash -s; fi"


def clean_line(raw: bytes) -> str:
    """Decoded line without ANSI codes; of a carriage-return progress bar only the last frame."""
    text = ANSI.sub("", raw.decode("utf-8", "replace")).rstrip("\r")
    return text.rsplit("\r", 1)[-1]


def load_script() -> str:
    return resources.files("deployer").joinpath("deploy-node.sh").read_text(encoding="utf-8")


def _array(name: str, pairs: tuple[tuple[str, str], ...]) -> str:
    return f"{name}=(" + " ".join(shlex.quote(f"{key}={value}") for key, value in pairs) + ")"


def build_payload(service: Service, script: str) -> str:
    """Header of quoted assignments followed by the node script, all sent on SSH stdin."""
    header = [
        f"DEPLOY_NAME={shlex.quote(service.name)}",
        f"DEPLOY_REPO={shlex.quote(service.repo)}",
        f"DEPLOY_REF={shlex.quote(service.ref)}",
        f"DEPLOY_BASE={shlex.quote(service.base_dir)}",
        f"DEPLOY_DIR={shlex.quote(service.directory)}",
        f"DEPLOY_ENV_FILE={shlex.quote(service.env_file)}",
        f"DEPLOY_BUILD={shlex.quote(service.build)}",
        f"DEPLOY_PRE={shlex.quote(service.pre)}",
        f"DEPLOY_START={shlex.quote(service.start)}",
        _array("DEPLOY_ENV", service.env),
        _array("DEPLOY_SHELL_ENV", service.shell_env),
    ]
    return "\n".join(header) + "\n" + script


def redact(line: str, secrets: tuple[str, ...]) -> str:
    for secret in secrets:
        line = line.replace(secret, "***")
    return line


class SshExecutor:
    """Executes a payload on a node. Unknown or changed host keys are rejected."""

    def __init__(self, known_hosts: str, connect_timeout: float = 15.0) -> None:
        self.known_hosts = known_hosts
        self.connect_timeout = connect_timeout

    def __call__(self, node: Node, payload: str, timeout: float, on_line: LineSink) -> int:
        if not Path(self.known_hosts).is_file():
            raise RuntimeError(f"known_hosts file {self.known_hosts} is missing; add the node's host key "
                               f"(ssh-keyscan -H {node.host} >> deployer-config/known_hosts) and verify its fingerprint")
        if not Path(node.ssh_key).is_file():
            raise RuntimeError(f"SSH key {node.ssh_key} for node {node.name} is not readable in the deployer container")
        client = paramiko.SSHClient()
        client.load_host_keys(self.known_hosts)
        client.set_missing_host_key_policy(paramiko.RejectPolicy())
        try:
            client.connect(
                node.host, port=node.port, username=node.user, key_filename=node.ssh_key,
                look_for_keys=False, allow_agent=False, timeout=self.connect_timeout,
                banner_timeout=self.connect_timeout, auth_timeout=self.connect_timeout,
            )
            return self._run(client, payload, timeout, on_line)
        finally:
            client.close()

    @classmethod
    def _run(cls, client: paramiko.SSHClient, payload: str, timeout: float, on_line: LineSink) -> int:
        token = secrets.token_hex(8)
        marker = f"__deploy:{token}:"
        seen: dict[str, str] = {}

        def emit(raw: bytes) -> None:
            text = clean_line(raw)
            if not text.startswith(marker):
                on_line(text)
                return
            kind, _, value = text[len(marker):].partition(":")
            if value.isdigit():
                seen[kind] = value

        stdin, stdout, _stderr = client.exec_command(REMOTE_COMMAND)
        channel = stdout.channel
        channel.set_combine_stderr(True)
        channel.settimeout(1.0)
        stdin.write(f"DEPLOY_TOKEN={token}\n{payload}")
        stdin.flush()
        channel.shutdown_write()
        deadline = time.monotonic() + timeout
        pending = b""
        while "exit" not in seen:
            if time.monotonic() > deadline:
                cls._terminate(client, seen.get("pgid"))
                channel.close()
                raise TimeoutError(f"deployment exceeded {int(timeout)}s")
            try:
                data = channel.recv(65536)
            except socket.timeout:
                continue
            if not data:
                break
            pending += data
            *lines, pending = pending.split(b"\n")
            if len(pending) > MAX_UNTERMINATED_BYTES:
                lines.append(pending)
                pending = b""
            for line in lines:
                emit(line)
        if pending and "exit" not in seen:
            emit(pending)
        return int(seen["exit"]) if "exit" in seen else channel.recv_exit_status()

    @staticmethod
    def _terminate(client: paramiko.SSHClient, pgid: str | None) -> None:
        """Best effort: stop the remote script and everything it started."""
        if not pgid:
            return
        try:
            _in, out, _err = client.exec_command(
                f"kill -TERM -- -{pgid} 2>/dev/null || kill -TERM {pgid} 2>/dev/null; sleep 3; "
                f"kill -KILL -- -{pgid} 2>/dev/null; true")
            out.channel.recv_exit_status()
        except Exception:
            pass


def port_reachable(url: str, timeout: float) -> bool:
    """True once the URL's host and port accept TCP connections, polling until `timeout` seconds."""
    parsed = urlparse(url)
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    deadline = time.monotonic() + timeout
    while True:
        try:
            with socket.create_connection((parsed.hostname, port), timeout=5):
                return True
        except OSError:
            if time.monotonic() >= deadline:
                return False
            time.sleep(5)
