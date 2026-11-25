from __future__ import annotations

import shutil
import socket
import subprocess
import tempfile
import threading
import types
import unittest
from pathlib import Path
from unittest import mock

from deployer.inventory import InventoryError, Service, parse_inventory
from deployer.jobs import DeployBusy, JobManager
from deployer.remote import SshExecutor, build_payload, clean_line, load_script, redact

DOCUMENT = {
    "defaults": {"node": {"user": "ubuntu", "ssh_key": "/keys/id"},
                 "service": {"shell_env": {"http_proxy": "http://proxy:911"}}},
    "nodes": {"a": {"host": "10.0.0.1"}, "b": {"host": "10.0.0.2", "user": "deploy", "port": 2222}},
    "services": {
        "kiosk": {"node": "a", "repo": "https://github.com/intel-retail/smart-kiosk-assistant.git",
                  "start": "make up", "build": "make build", "env": {"HF_TOKEN": "s3cr3t-token", "N": 4},
                  "mcp_url": "http://10.0.0.1:8014/mcp"},
        "accuracy": {"node": "b", "repo": "https://github.com/intel-retail/order-accuracy.git",
                     "dir": "take-away", "start": "make up", "ref": "v1.2", "shell_env": {"X": "1"}},
    },
}


def document(**services: dict) -> dict:
    return {**DOCUMENT, "services": services or DOCUMENT["services"]}


class InventoryTests(unittest.TestCase):
    def test_parses_defaults_and_order(self) -> None:
        inventory = parse_inventory(DOCUMENT)
        self.assertEqual(list(inventory.services), ["kiosk", "accuracy"])
        self.assertEqual(inventory.nodes["a"].user, "ubuntu")
        self.assertEqual((inventory.nodes["b"].user, inventory.nodes["b"].port), ("deploy", 2222))
        kiosk = inventory.services["kiosk"]
        self.assertEqual(kiosk.ref, "main")
        self.assertEqual(kiosk.env, (("HF_TOKEN", "s3cr3t-token"), ("N", "4")))
        self.assertEqual(inventory.services["accuracy"].shell_env, (("http_proxy", "http://proxy:911"), ("X", "1")))

    def test_select_all_subset_and_unknown(self) -> None:
        inventory = parse_inventory(DOCUMENT)
        self.assertEqual([s.name for s in inventory.select(None)], ["kiosk", "accuracy"])
        self.assertEqual([s.name for s in inventory.select(["accuracy"])], ["accuracy"])
        with self.assertRaisesRegex(InventoryError, "unknown service.*nope"):
            inventory.select(["nope"])

    def test_rejects_unsafe_values(self) -> None:
        base = {"node": "a", "repo": "https://github.com/o/r.git", "start": "make up"}
        for change in (
            {"repo": "http://github.com/o/r.git"},
            {"repo": "https://github.com/o/r.git; rm -rf /"},
            {"ref": "--upload-pack=x"},
            {"dir": "../etc"},
            {"dir": "/abs"},
            {"env_file": "../.env"},
            {"base_dir": "~/a/../b"},
            {"node": "missing"},
            {"env": {"BAD NAME": "1"}},
            {"env": {"K": "line1\nline2"}},
            {"mcp_url": "ftp://x/mcp"},
            {"start": None},
        ):
            with self.subTest(change=change):
                entry = {**base, **change}
                if entry.get("start") is None:
                    entry.pop("start")
                with self.assertRaises(InventoryError):
                    parse_inventory(document(svc=entry))

    def test_rejects_unsafe_node_and_empty_inventory(self) -> None:
        for nodes in ({"a": {"host": "10.0.0.1; id"}}, {"a": {"host": "h", "user": "Root Me"}}, {}):
            with self.subTest(nodes=nodes), self.assertRaises(InventoryError):
                parse_inventory({**DOCUMENT, "nodes": nodes})
        with self.assertRaises(InventoryError):
            parse_inventory({**DOCUMENT, "services": {}})


def service(**changes) -> Service:
    values = dict(name="svc", node="a", repo="https://example.com/r.git", ref="main", directory="",
                  build="", start="true", env_file=".env", env=(), shell_env=(), base_dir="~/qsr",
                  timeout_seconds=60, mcp_url="", verify_seconds=0)
    return Service(**{**values, **changes})


class PayloadTests(unittest.TestCase):
    def test_payload_quotes_hostile_values(self) -> None:
        payload = build_payload(service(start="echo $(id) 'x'", env=(("K", "a b'; id #"),)), "SCRIPT")
        self.assertIn("DEPLOY_START='echo $(id) '\"'\"'x'\"'\"''", payload)
        self.assertIn("DEPLOY_ENV=('K=a b'\"'\"'; id #')", payload)
        self.assertTrue(payload.endswith("\nSCRIPT"))

    def test_redact(self) -> None:
        self.assertEqual(redact("token=abcd1234 ok", ("abcd1234",)), "token=*** ok")

    def test_pre_is_parsed_and_quoted_into_the_payload(self) -> None:
        entry = {**DOCUMENT["services"]["kiosk"], "pre": "chmod -R u+w 'a b'"}
        parsed = parse_inventory(document(kiosk=entry)).services["kiosk"]
        self.assertEqual(parsed.pre, "chmod -R u+w 'a b'")
        self.assertIn("DEPLOY_PRE='chmod -R u+w '\"'\"'a b'\"'\"''", build_payload(parsed, "SCRIPT"))
        self.assertEqual(parse_inventory(DOCUMENT).services["kiosk"].pre, "")

    def test_clean_line_keeps_last_progress_frame_and_drops_ansi(self) -> None:
        self.assertEqual(clean_line(b"\x1b[1mstep 1\x1b[0m\r10%\r55%\r100% done\r"), "100% done")
        self.assertEqual(clean_line(b"plain"), "plain")


def bash_path(path: Path) -> str:
    """Path as bash sees it (Git Bash maps C:\\x to /c/x on Windows)."""
    posix = path.as_posix()
    return f"/{posix[0].lower()}{posix[2:]}" if len(posix) > 2 and posix[1] == ":" else posix


def _working_bash() -> bool:
    if not (shutil.which("bash") and shutil.which("git")):
        return False
    try:  # on Windows `bash` can be a WSL stub with no distribution installed
        return subprocess.run(["bash", "-c", "awk 'BEGIN{}' && echo ok"], capture_output=True, text=True,
                              timeout=30).stdout.strip() == "ok"
    except (OSError, subprocess.SubprocessError):
        return False


@unittest.skipUnless(_working_bash(), "bash, git and awk required")
class NodeScriptTests(unittest.TestCase):
    def run_payload(self, payload: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["bash", "-s"], input=payload, capture_output=True, text=True, timeout=120)

    def make_repo(self, root: Path) -> Path:
        repo = root / "origin"
        (repo / "sub").mkdir(parents=True)
        (repo / "sub" / ".env.example").write_text("KEEP=1\nTOKEN=old\n", encoding="utf-8", newline="\n")
        git = ["git", "-C", str(repo)]
        subprocess.run([*git[:1], "init", "-q", "-b", "main", str(repo)], check=True)
        subprocess.run([*git, "add", "."], check=True)
        subprocess.run([*git, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"], check=True)
        return repo

    def test_clone_env_build_start_and_redeploy(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self.make_repo(root)
            base = bash_path(root / "nodes")
            svc = service(repo=repo.as_posix(), directory="sub", base_dir=base,
                          env=(("TOKEN", "new value=with$pecial"), ("ADDED", "yes")),
                          shell_env=(("MARK", "from-shell-env"),),
                          build="echo built > build.out", start='echo "$MARK" > start.out')
            payload = build_payload(svc, load_script().replace("\r\n", "\n"))
            for _ in range(2):  # second run exercises the update path
                result = self.run_payload(payload)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            work = root / "nodes" / "svc" / "sub"
            self.assertEqual((work / ".env").read_text(encoding="utf-8").splitlines(),
                             ["KEEP=1", "TOKEN=new value=with$pecial", "ADDED=yes"])
            self.assertEqual((work / "start.out").read_text(encoding="utf-8").strip(), "from-shell-env")
            self.assertTrue((work / "build.out").exists())

    def test_pre_runs_in_existing_checkout_only_and_failure_stops_the_deploy(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self.make_repo(root)
            script = load_script().replace("\r\n", "\n")
            base = bash_path(root / "n")
            svc = service(repo=repo.as_posix(), base_dir=base, pre="echo ran > pre.out", start="true")
            self.assertEqual(self.run_payload(build_payload(svc, script)).returncode, 0)
            self.assertFalse((root / "n" / "svc" / "pre.out").exists())  # first deploy: no checkout yet
            self.assertEqual(self.run_payload(build_payload(svc, script)).returncode, 0)
            self.assertTrue((root / "n" / "svc" / "pre.out").exists())
            failing = service(repo=repo.as_posix(), base_dir=base, pre="exit 9", start="echo started > started.out")
            self.assertNotEqual(self.run_payload(build_payload(failing, script)).returncode, 0)
            self.assertFalse((root / "n" / "svc" / "started.out").exists())

    def test_failing_start_returns_nonzero(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            svc = service(repo=self.make_repo(root).as_posix(), base_dir=bash_path(root / "n"), start="exit 7")
            result = self.run_payload(build_payload(svc, load_script().replace("\r\n", "\n")))
            self.assertEqual(result.returncode, 7)

    def test_token_adds_pgid_and_exit_markers(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            svc = service(repo=self.make_repo(root).as_posix(), base_dir=bash_path(root / "n"), start="exit 7")
            payload = "DEPLOY_TOKEN=tok\n" + build_payload(svc, load_script().replace("\r\n", "\n"))
            lines = self.run_payload(payload).stdout.splitlines()
            self.assertTrue(lines[0].startswith("__deploy:tok:pgid:"))
            self.assertEqual(lines[-1], "__deploy:tok:exit:7")


class FakeChannel:
    def __init__(self, chunks, hang=False):
        self.chunks, self.hang, self.closed = list(chunks), hang, False

    def set_combine_stderr(self, _flag): ...
    def settimeout(self, _seconds): ...
    def shutdown_write(self): ...
    def close(self): self.closed = True
    def recv_exit_status(self): return 0

    def recv(self, _size):
        if self.chunks:
            return self.chunks.pop(0)
        if self.hang:  # a detached process still holds the channel open
            raise socket.timeout
        return b""


class FakeClient:
    def __init__(self, channel):
        self.channel, self.commands, self.written = channel, [], []

    def exec_command(self, command):
        self.commands.append(command)
        stdin = types.SimpleNamespace(write=self.written.append, flush=lambda: None)
        stdout = types.SimpleNamespace(channel=self.channel)
        return stdin, stdout, None


class SshRunTests(unittest.TestCase):
    def test_exit_marker_ends_the_run_even_if_the_channel_stays_open(self) -> None:
        channel = FakeChannel([b"__deploy:tok:pgid:42\nbuilding\n", b"__deploy:tok:exit:5\n"], hang=True)
        client = FakeClient(channel)
        lines: list[str] = []
        with mock.patch("deployer.remote.secrets.token_hex", return_value="tok"):
            code = SshExecutor._run(client, "PAYLOAD", 5, lines.append)
        self.assertEqual((code, lines), (5, ["building"]))
        self.assertTrue(client.written[0].startswith("DEPLOY_TOKEN=tok\n"))

    def test_marker_with_another_token_is_ordinary_output(self) -> None:
        channel = FakeChannel([b"__deploy:other:exit:0\n"])
        lines: list[str] = []
        with mock.patch("deployer.remote.secrets.token_hex", return_value="tok"):
            self.assertEqual(SshExecutor._run(FakeClient(channel), "PAYLOAD", 5, lines.append), 0)
        self.assertEqual(lines, ["__deploy:other:exit:0"])

    def test_timeout_kills_the_remote_process_group(self) -> None:
        channel = FakeChannel([b"__deploy:tok:pgid:42\n"], hang=True)
        client = FakeClient(channel)
        with mock.patch("deployer.remote.secrets.token_hex", return_value="tok"), \
                self.assertRaises(TimeoutError):
            SshExecutor._run(client, "PAYLOAD", 0.01, lambda line: None)
        self.assertTrue(channel.closed)
        self.assertIn("kill -TERM -- -42", client.commands[-1])


class JobTests(unittest.TestCase):
    def manager(self, executor, verifier=lambda url, timeout: True) -> JobManager:
        inventory = parse_inventory(DOCUMENT)
        return JobManager(lambda: inventory, lambda known_hosts: executor, "SCRIPT", verifier)

    def test_all_services_succeed_in_order_with_verification_and_redaction(self) -> None:
        seen: list[tuple[str, str]] = []

        def executor(node, payload, timeout, on_line):
            seen.append((node.host, payload))
            on_line("login with s3cr3t-token done" if node.host == "10.0.0.1" else "ok")
            return 0

        manager = self.manager(executor, lambda url, timeout: url.endswith("8014/mcp"))
        job = manager.start(None)
        manager.wait(job["job_id"], 10)
        status = manager.status(job["job_id"])
        self.assertEqual(status["status"], "succeeded")
        self.assertEqual([host for host, _ in seen], ["10.0.0.1", "10.0.0.2"])
        kiosk, accuracy = status["services"]
        self.assertEqual((kiosk["status"], kiosk["verified"]), ("succeeded", True))
        self.assertEqual((accuracy["status"], accuracy["verified"]), ("succeeded", None))
        self.assertEqual(kiosk["log_tail"], ["login with *** done"])
        self.assertNotIn("s3cr3t-token", str(status))

    def test_failure_does_not_stop_other_services(self) -> None:
        def executor(node, payload, timeout, on_line):
            if node.host == "10.0.0.1":
                raise RuntimeError("known_hosts file missing")
            return 3

        manager = self.manager(executor)
        job = manager.start(None)
        manager.wait(job["job_id"], 10)
        status = manager.status()
        self.assertEqual(status["status"], "failed")
        kiosk, accuracy = status["services"]
        self.assertIn("known_hosts", kiosk["error"])
        self.assertEqual((accuracy["status"], accuracy["exit_code"]), ("failed", 3))

    def test_subset_and_unknown_service(self) -> None:
        manager = self.manager(lambda *args: 0)
        job = manager.start(["accuracy"])
        manager.wait(job["job_id"], 10)
        self.assertEqual([s["service"] for s in manager.status()["services"]], ["accuracy"])
        with self.assertRaises(InventoryError):
            manager.start(["nope"])
        with self.assertRaises(InventoryError):
            manager.status("missing")

    def test_second_deployment_is_refused_while_running(self) -> None:
        release = threading.Event()
        manager = self.manager(lambda *args: (release.wait(10), 0)[1])
        job = manager.start(["kiosk"])
        with self.assertRaises(DeployBusy):
            manager.start(["accuracy"])
        release.set()
        manager.wait(job["job_id"], 10)
        self.assertEqual(manager.status()["status"], "succeeded")
        manager.wait(manager.start(["accuracy"])["job_id"], 10)

    def test_status_with_no_jobs(self) -> None:
        self.assertEqual(self.manager(lambda *args: 0).status()["status"], "none")


class AgentEnvTests(unittest.TestCase):
    def test_agent_env_is_parsed_and_validated(self) -> None:
        entry = {"node": "a", "repo": "https://github.com/o/r.git", "start": "make up"}
        inventory = parse_inventory(document(svc={**entry, "agent_env": {"QSR_KIOSK_MCP_URL": "http://h:8014/mcp"}}))
        self.assertEqual(inventory.services["svc"].agent_env, (("QSR_KIOSK_MCP_URL", "http://h:8014/mcp"),))
        for bad in ({"BAD NAME": "http://h/mcp"}, {"QSR_X": "not a url"}):
            with self.assertRaises(InventoryError):
                parse_inventory(document(svc={**entry, "agent_env": bad}))


try:
    from starlette.applications import Starlette
    from starlette.responses import PlainTextResponse
    from starlette.routing import Route
    from starlette.testclient import TestClient
    from deployer.auth import BearerAuth
except ImportError:
    TestClient = None


@unittest.skipIf(TestClient is None, "starlette required")
class AuthTests(unittest.TestCase):
    def client(self) -> "TestClient":
        async def ok(_request):
            return PlainTextResponse("ok")

        app = Starlette(routes=[Route("/mcp", ok), Route("/health", ok)])
        return TestClient(BearerAuth(app, "t" * 16))

    def test_requires_exact_bearer_token_except_health(self) -> None:
        client = self.client()
        self.assertEqual(client.get("/health").status_code, 200)
        self.assertEqual(client.get("/mcp").status_code, 401)
        self.assertEqual(client.get("/mcp", headers={"Authorization": "Bearer wrong"}).status_code, 401)
        self.assertEqual(client.get("/mcp", headers={"Authorization": "Bearer " + "t" * 16}).status_code, 200)


try:
    from fastmcp import Client
except ImportError:  # the server wiring is exercised only where fastmcp is installed
    Client = None


@unittest.skipIf(Client is None, "fastmcp required")
class ServerTests(unittest.IsolatedAsyncioTestCase):
    async def test_tools_and_read_only_hints(self) -> None:
        from deployer.server import build_server

        inventory = parse_inventory(DOCUMENT)
        manager = JobManager(lambda: inventory, lambda known_hosts: (lambda *args: 0), "SCRIPT", lambda u, t: True)
        async with Client(build_server(manager, lambda: inventory)) as client:
            tools = {tool.name: tool for tool in await client.list_tools()}
            self.assertEqual(set(tools), {"describe_deploy_plan", "deploy_services", "get_deployment_status"})
            self.assertTrue(tools["describe_deploy_plan"].annotations.read_only_hint)
            self.assertFalse(tools["deploy_services"].annotations.read_only_hint)
            plan = (await client.call_tool("describe_deploy_plan", {})).data
            self.assertEqual([step["service"] for step in plan["steps"]], ["kiosk", "accuracy"])
            self.assertEqual(plan["steps"][0]["env_variables"], ["HF_TOKEN", "N"])
            self.assertNotIn("s3cr3t-token", str(plan))
            started = (await client.call_tool("deploy_services", {"services": ["kiosk"]})).data
            manager.wait(started["job_id"], 10)
            status = (await client.call_tool("get_deployment_status", {})).data
            self.assertEqual(status["status"], "succeeded")


if __name__ == "__main__":
    unittest.main()
