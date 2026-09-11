"""Tests for the China-friendly Ascend docs npm launcher."""

from __future__ import annotations

import io
import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from msagent.mcp.launchers import ascend_doc_mcp


def test_registry_candidates_prefer_user_registry_and_support_only(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("MSAGENT_NPM_REGISTRY", "https://npm.example.com")
    monkeypatch.setenv("MSAGENT_NPM_REGISTRY_ONLY", "1")

    assert ascend_doc_mcp._registry_candidates() == ["https://npm.example.com"]


def test_registry_candidates_include_default_fallbacks(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("MSAGENT_NPM_REGISTRY", "https://npm.example.com")
    monkeypatch.delenv("MSAGENT_NPM_REGISTRY_ONLY", raising=False)

    assert ascend_doc_mcp._registry_candidates() == [
        "https://npm.example.com",
        "https://registry.npmmirror.com",
        "https://registry.npmjs.org",
    ]


def test_select_registry_requires_explicit_registry_in_only_mode(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("MSAGENT_NPM_REGISTRY", raising=False)
    monkeypatch.setenv("MSAGENT_NPM_REGISTRY_ONLY", "1")

    with pytest.raises(RuntimeError, match="requires MSAGENT_NPM_REGISTRY"):
        ascend_doc_mcp.select_registry()


def test_select_registry_probes_package_metadata_and_falls_back(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[list[str]] = []

    def fake_run(command, **kwargs):
        calls.append(command)
        if "https://registry.npmmirror.com" in command:
            return SimpleNamespace(returncode=1, stdout="", stderr="unreachable")
        return SimpleNamespace(returncode=0, stdout='"1.2.3"\n', stderr="")

    monkeypatch.setattr(ascend_doc_mcp.subprocess, "run", fake_run)

    selection = ascend_doc_mcp.select_registry(version="1.2.3")

    assert selection.registry == "https://registry.npmjs.org"
    assert calls[0] == [
        ascend_doc_mcp._tool_command("npm"),
        "view",
        "@opencxd/ascend-doc-mcp@1.2.3",
        "version",
        "--registry",
        "https://registry.npmmirror.com",
        "--json",
    ]


def test_select_registry_rejects_invalid_metadata(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        ascend_doc_mcp.subprocess,
        "run",
        lambda *_args, **_kwargs: SimpleNamespace(returncode=0, stdout="not-json", stderr=""),
    )

    with pytest.raises(RuntimeError, match="Unable to resolve"):
        ascend_doc_mcp.select_registry(version="latest")


def test_build_npx_command_uses_registry_and_fixed_version() -> None:
    assert ascend_doc_mcp.build_npx_command(
        registry="https://registry.npmmirror.com",
        version="1.2.3",
    ) == [
        ascend_doc_mcp._tool_command("npx"),
        "--yes",
        "--registry",
        "https://registry.npmmirror.com",
        "@opencxd/ascend-doc-mcp@1.2.3",
    ]


def test_main_reports_missing_tooling_on_stderr(
    monkeypatch: pytest.MonkeyPatch,
    capsys,
    tmp_path,
) -> None:
    monkeypatch.setenv("MSAGENT_ASCEND_DOC_MCP_PREFIX", str(tmp_path / "no-local-install"))
    monkeypatch.setenv("MSAGENT_NODE_HOME", str(tmp_path / "no-node-home"))
    monkeypatch.setattr(
        ascend_doc_mcp.shutil,
        "which",
        lambda command: None if command in {"npx", "npx.cmd", "npx.exe"} else command,
    )

    assert ascend_doc_mcp.main() == 127
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "Missing required Node.js tooling: npx" in captured.err


def test_windows_tool_resolution_prefers_cmd_wrapper(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path,
) -> None:
    monkeypatch.setenv("MSAGENT_NODE_HOME", str(tmp_path / "no-node-home"))
    monkeypatch.setattr(ascend_doc_mcp, "_is_windows", lambda: True)
    monkeypatch.setattr(
        ascend_doc_mcp.shutil,
        "which",
        lambda command: "C:\\Program Files\\nodejs\\npm.cmd" if command == "npm.cmd" else None,
    )

    assert ascend_doc_mcp._tool_command("npm") == "npm.cmd"


def test_main_keeps_child_process_on_stdio_and_diagnostics_on_stderr(
    monkeypatch: pytest.MonkeyPatch,
    capsys,
    tmp_path,
) -> None:
    monkeypatch.setenv("MSAGENT_ASCEND_DOC_MCP_PREFIX", str(tmp_path / "no-local-install"))
    monkeypatch.setenv("MSAGENT_NODE_HOME", str(tmp_path / "no-node-home"))
    monkeypatch.setenv("MSAGENT_ASCEND_DOC_MCP_VERBOSE", "1")
    monkeypatch.setattr(ascend_doc_mcp.shutil, "which", lambda _command: "tool")
    monkeypatch.setattr(
        ascend_doc_mcp,
        "select_registry",
        lambda **_kwargs: ascend_doc_mcp.RegistrySelection(
            registry="https://registry.npmmirror.com",
            diagnostics=["selected"],
        ),
    )
    commands: list[list[str]] = []

    def fake_run_mcp_server(command):
        commands.append(command)
        return 0

    monkeypatch.setattr(ascend_doc_mcp, "_run_mcp_server", fake_run_mcp_server)

    assert ascend_doc_mcp.main() == 0
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "selected" in captured.err
    assert commands == [
        [
            ascend_doc_mcp._tool_command("npx"),
            "--yes",
            "--registry",
            "https://registry.npmmirror.com",
            "@opencxd/ascend-doc-mcp@latest",
        ]
    ]


def test_forward_mcp_stdout_keeps_protocol_messages_on_stdout() -> None:
    upstream = io.BytesIO(
        "启动日志\n"
        '{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}\n'
        '{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}\n'
        "not json\n".encode("utf-8")
    )
    protocol = io.BytesIO()
    diagnostics = io.BytesIO()

    ascend_doc_mcp._forward_mcp_stdout(upstream, protocol, diagnostics)

    assert protocol.getvalue() == (
        b'{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}\n'
        b'{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}\n'
    )
    assert diagnostics.getvalue() == "启动日志\nnot json\n".encode("utf-8")


def test_forward_mcp_stdout_rejects_json_that_is_not_jsonrpc() -> None:
    upstream = io.BytesIO(b'{"message":"diagnostic"}\n[1, 2, 3]\n')
    protocol = io.BytesIO()
    diagnostics = io.BytesIO()

    ascend_doc_mcp._forward_mcp_stdout(upstream, protocol, diagnostics)

    assert protocol.getvalue() == b""
    assert diagnostics.getvalue() == b'{"message":"diagnostic"}\n[1, 2, 3]\n'


def test_run_mcp_server_proxies_stdio_and_returns_child_code(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    protocol = io.BytesIO()
    diagnostics = io.BytesIO()
    stdin = io.BytesIO(b'{"jsonrpc":"2.0","method":"initialize"}\n')

    class FakeChild:
        stdout = io.BytesIO("启动日志\n".encode("utf-8") + b'{"jsonrpc":"2.0"}\n')

        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return False

        def wait(self) -> int:
            return 23

    calls: list[tuple[list[str], dict[str, object]]] = []

    def fake_popen(command, **kwargs):
        calls.append((command, kwargs))
        return FakeChild()

    monkeypatch.setattr(ascend_doc_mcp.subprocess, "Popen", fake_popen)
    monkeypatch.setattr(ascend_doc_mcp.sys, "stdin", SimpleNamespace(buffer=stdin))
    monkeypatch.setattr(ascend_doc_mcp.sys, "stdout", SimpleNamespace(buffer=protocol))
    monkeypatch.setattr(ascend_doc_mcp.sys, "stderr", SimpleNamespace(buffer=diagnostics))
    monkeypatch.setenv("MSAGENT_ASCEND_DOC_MCP_VERBOSE", "1")

    assert ascend_doc_mcp._run_mcp_server(["npx", "server"]) == 23
    assert calls[0][0] == ["npx", "server"]
    assert calls[0][1]["stdin"] is stdin
    assert calls[0][1]["stdout"] is ascend_doc_mcp.subprocess.PIPE
    assert calls[0][1]["stderr"] is diagnostics
    assert protocol.getvalue() == b'{"jsonrpc":"2.0"}\n'
    assert diagnostics.getvalue() == "启动日志\n".encode("utf-8")


def _write_local_package(prefix, *, bin_as_object: bool = True) -> Path:
    pkg_dir = prefix / "node_modules" / "@opencxd" / "ascend-doc-mcp"
    (pkg_dir / "dist").mkdir(parents=True)
    (pkg_dir / "dist" / "cli.js").write_text("// fake cli\n", encoding="utf-8")
    bin_field = {"ascend-doc-mcp": "./dist/cli.js"} if bin_as_object else "./dist/cli.js"
    (pkg_dir / "package.json").write_text(
        json.dumps({"name": "@opencxd/ascend-doc-mcp", "bin": bin_field}),
        encoding="utf-8",
    )
    return pkg_dir / "dist" / "cli.js"


@pytest.mark.parametrize("bin_as_object", [True, False])
def test_main_prefers_local_install_over_npx(
    monkeypatch: pytest.MonkeyPatch,
    capsys,
    tmp_path,
    bin_as_object: bool,
) -> None:
    prefix = tmp_path / "prefix"
    script = _write_local_package(prefix, bin_as_object=bin_as_object)
    node_home = tmp_path / "node-home"
    node_home.mkdir(parents=True, exist_ok=True)
    if ascend_doc_mcp.os.name == "nt":
        node_bin = node_home / "node.exe"
    else:
        (node_home / "bin").mkdir(parents=True, exist_ok=True)
        node_bin = node_home / "bin" / "node"
    node_bin.write_text("", encoding="utf-8")
    monkeypatch.setenv("MSAGENT_NODE_HOME", str(node_home))
    monkeypatch.setenv("MSAGENT_ASCEND_DOC_MCP_PREFIX", str(prefix))
    monkeypatch.setenv("MSAGENT_ASCEND_DOC_MCP_VERBOSE", "1")
    monkeypatch.setattr(
        ascend_doc_mcp.shutil,
        "which",
        lambda _command: (_ for _ in ()).throw(AssertionError("PATH must not be consulted")),
    )
    monkeypatch.setattr(
        ascend_doc_mcp,
        "select_registry",
        lambda **_kwargs: (_ for _ in ()).throw(AssertionError("must not probe registry")),
    )
    commands: list[list[str]] = []

    def fake_run_mcp_server(command):
        commands.append(command)
        return 0

    monkeypatch.setattr(ascend_doc_mcp, "_run_mcp_server", fake_run_mcp_server)

    assert ascend_doc_mcp.main() == 0
    captured = capsys.readouterr()
    assert "running local install" in captured.err
    assert commands == [[str(node_bin), str(script)]]


def test_main_falls_back_to_npx_for_incomplete_local_install(
    monkeypatch: pytest.MonkeyPatch,
    capsys,
    tmp_path,
) -> None:
    prefix = tmp_path / "prefix"
    prefix.mkdir()  # exists but has no installed package
    monkeypatch.setenv("MSAGENT_ASCEND_DOC_MCP_PREFIX", str(prefix))
    monkeypatch.setenv("MSAGENT_NODE_HOME", str(tmp_path / "no-node-home"))
    monkeypatch.setattr(ascend_doc_mcp.shutil, "which", lambda _command: "tool")
    monkeypatch.setattr(
        ascend_doc_mcp,
        "select_registry",
        lambda **_kwargs: ascend_doc_mcp.RegistrySelection(
            registry="https://registry.npmmirror.com",
            diagnostics=["selected"],
        ),
    )
    commands: list[list[str]] = []

    def fake_run_mcp_server(command):
        commands.append(command)
        return 0

    monkeypatch.setattr(ascend_doc_mcp, "_run_mcp_server", fake_run_mcp_server)

    assert ascend_doc_mcp.main() == 0
    assert commands == [
        [
            ascend_doc_mcp._tool_command("npx"),
            "--yes",
            "--registry",
            "https://registry.npmmirror.com",
            "@opencxd/ascend-doc-mcp@latest",
        ]
    ]


def test_node_home_is_preferred_for_tool_resolution(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path,
) -> None:
    """MSAGENT_NODE_HOME is consulted before PATH, on POSIX and Windows."""
    node_home = tmp_path / "node-home"
    node_home.mkdir(parents=True, exist_ok=True)
    if ascend_doc_mcp.os.name == "nt":
        expected = {}
        for name, key in (("node.exe", "node"), ("npm.cmd", "npm"), ("npx.cmd", "npx")):
            (node_home / name).write_text("", encoding="utf-8")
            expected[key] = node_home / name
    else:
        (node_home / "bin").mkdir(parents=True)
        expected = {}
        for name in ("node", "npm", "npx"):
            (node_home / "bin" / name).write_text("", encoding="utf-8")
            expected[name] = node_home / "bin" / name
    monkeypatch.setenv("MSAGENT_NODE_HOME", str(node_home))
    monkeypatch.setattr(
        ascend_doc_mcp.shutil,
        "which",
        lambda _command: (_ for _ in ()).throw(AssertionError("PATH must not be consulted")),
    )

    assert ascend_doc_mcp._resolve_tool("node") == str(expected["node"])
    assert ascend_doc_mcp._resolve_tool("npm") == str(expected["npm"])
    assert ascend_doc_mcp._resolve_tool("npx") == str(expected["npx"])


def test_main_is_quiet_by_default(
    monkeypatch: pytest.MonkeyPatch,
    capsys,
    tmp_path,
) -> None:
    """Successful local runs must not print informational diagnostics."""
    prefix = tmp_path / "prefix"
    script = _write_local_package(prefix)
    node_home = tmp_path / "node-home"
    node_home.mkdir(parents=True, exist_ok=True)
    if ascend_doc_mcp.os.name == "nt":
        node_bin = node_home / "node.exe"
    else:
        (node_home / "bin").mkdir(parents=True, exist_ok=True)
        node_bin = node_home / "bin" / "node"
    node_bin.write_text("", encoding="utf-8")
    monkeypatch.setenv("MSAGENT_NODE_HOME", str(node_home))
    monkeypatch.setenv("MSAGENT_ASCEND_DOC_MCP_PREFIX", str(prefix))
    monkeypatch.setattr(
        ascend_doc_mcp.shutil,
        "which",
        lambda _command: (_ for _ in ()).throw(AssertionError("PATH must not be consulted")),
    )
    monkeypatch.setattr(
        ascend_doc_mcp,
        "select_registry",
        lambda **_kwargs: (_ for _ in ()).throw(AssertionError("must not probe registry")),
    )

    def fake_run_mcp_server(command):
        assert command == [str(node_bin), str(script)]
        return 0

    monkeypatch.setattr(ascend_doc_mcp, "_run_mcp_server", fake_run_mcp_server)

    assert ascend_doc_mcp.main() == 0
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err == ""


def test_main_reports_nonzero_exit_code_in_quiet_mode(
    monkeypatch: pytest.MonkeyPatch,
    capsys,
    tmp_path,
) -> None:
    prefix = tmp_path / "prefix"
    script = _write_local_package(prefix)
    node_home = tmp_path / "node-home"
    node_home.mkdir(parents=True, exist_ok=True)
    if ascend_doc_mcp.os.name == "nt":
        node_bin = node_home / "node.exe"
    else:
        (node_home / "bin").mkdir(parents=True, exist_ok=True)
        node_bin = node_home / "bin" / "node"
    node_bin.write_text("", encoding="utf-8")
    monkeypatch.setenv("MSAGENT_NODE_HOME", str(node_home))
    monkeypatch.setenv("MSAGENT_ASCEND_DOC_MCP_PREFIX", str(prefix))
    monkeypatch.setattr(
        ascend_doc_mcp.shutil,
        "which",
        lambda _command: (_ for _ in ()).throw(AssertionError("PATH must not be consulted")),
    )
    monkeypatch.setattr(
        ascend_doc_mcp,
        "select_registry",
        lambda **_kwargs: (_ for _ in ()).throw(AssertionError("must not probe registry")),
    )

    def fake_run_mcp_server(command):
        assert command == [str(node_bin), str(script)]
        return 23

    monkeypatch.setattr(ascend_doc_mcp, "_run_mcp_server", fake_run_mcp_server)

    assert ascend_doc_mcp.main() == 23
    captured = capsys.readouterr()
    assert "exited with code 23" in captured.err
