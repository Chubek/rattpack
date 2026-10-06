"""Offline regression tests for the stdlib-only MCP server."""

import importlib.util
import json
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
TEMP_ROOT = "/tmp/opencode" if Path("/tmp/opencode").is_dir() else None


def load_mcp():
    spec = importlib.util.spec_from_file_location(
        "rattpack_mcp", ROOT / "tools" / "rattpack-mcp.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


mcp = load_mcp()


def fixture(root):
    (root / "src").mkdir(parents=True)
    (root / "src" / "main.c").write_text("int main(void) { return 0; }\n")
    (root / "src" / "util.c").write_text("int util(void) { return 1; }\n")
    (root / "zlib").mkdir()
    return root


class McpTests(unittest.TestCase):
    def test_scan_suggests_c_executable(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            scan = mcp.scan_directory(fixture(Path(directory)))
            self.assertEqual(scan["source_counts"], {"c": 2, "cxx": 0, "d": 0})
            self.assertEqual(scan["suggested_language"], "c")
            self.assertEqual(scan["suggested_target"], "exe")
            # ls2rattpkg treats every immediate subdirectory as a
            # dependency candidate, including source roots.
            self.assertEqual(scan["libraries"], ["src", "zlib"])

    def test_scan_detects_monorepo_members(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            root = fixture(Path(directory))
            (root / "libs" / "one").mkdir(parents=True)
            (root / "libs" / "one" / "Rattspec").write_text(
                'project(name: "one", version: "1", kind: "single")\n')
            scan = mcp.scan_directory(root)
            self.assertEqual(scan["nested_specs"], ["libs/one/Rattspec"])

    def test_generate_project_writes_matching_identity(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            root = fixture(Path(directory))
            fake_ls = types.SimpleNamespace(
                package_name=lambda text: text,
                render=lambda *a: "package-rendered\n",
                libraries=lambda d: {"zlib": d / "zlib"},
                discover=lambda *a, **k: ("https://example.org/zlib.git",
                                          "d" * 40),
            )
            fake_github = types.SimpleNamespace(
                load_credentials=lambda *a, **k: None)
            with patch.object(mcp, "ls2rattpkg_module", return_value=fake_ls), \
                    patch.object(mcp, "github_module", return_value=fake_github):
                summary = mcp.generate_project(root, name="demo")
            spec = (root / "Rattspec").read_text()
            self.assertIn('project(name: "demo"', spec)
            self.assertIn("target.executable", spec)
            self.assertIn('fs.glob("src/**/*.c")', spec)
            self.assertEqual((root / "Rattpkg").read_text(), "package-rendered\n")
            self.assertEqual(summary["rattspec"]["kind"], "single")
            self.assertEqual(summary["rattpkg"]["dependencies"],
                             [{"name": "zlib",
                               "url": "https://example.org/zlib.git",
                               "rev": "d" * 40}])

    def test_generate_project_monorepo_and_no_overwrite(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            root = fixture(Path(directory))
            (root / "libs" / "one").mkdir(parents=True)
            (root / "libs" / "one" / "Rattspec").write_text(
                'project(name: "one", version: "1", kind: "single")\n')
            summary = mcp.generate_project(root, name="demo",
                                           write_rattpkg=False)
            self.assertIn('member "libs/one"',
                          (root / "Rattspec").read_text())
            self.assertEqual(summary["rattspec"]["kind"], "monorepo")
            with self.assertRaises(ValueError):
                mcp.generate_rattspec(root, name="demo")
            rerun = mcp.generate_rattspec(root, name="demo", force=True)
            self.assertEqual(rerun["kind"], "monorepo")

    def test_exclude_skips_source_roots(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            root = fixture(Path(directory))
            fake_ls = types.SimpleNamespace(
                package_name=lambda text: text,
                render=lambda name, version, lic, deps, un: repr(sorted(deps)),
                libraries=lambda d: {"src": d / "src", "zlib": d / "zlib"},
                discover=lambda n, *a, **k: (f"https://example.org/{n}.git",
                                             "e" * 40),
            )
            fake_github = types.SimpleNamespace(
                load_credentials=lambda *a, **k: None)
            with patch.object(mcp, "ls2rattpkg_module", return_value=fake_ls), \
                    patch.object(mcp, "github_module", return_value=fake_github):
                included = mcp.generate_rattpkg(root, exclude=["src"])
                self.assertEqual([d["name"] for d in included["dependencies"]],
                                 ["zlib"])
                self.assertEqual(included["unresolved"], [])
                with self.assertRaises(ValueError):
                    mcp.generate_rattpkg(root, exclude=["src"],
                                         repo={"src": "https://example.org/x.git"},
                                         force=True)

    def test_handshake_lists_five_tools_and_calls_scan(self):
        response = mcp.handle_request({"jsonrpc": "2.0", "id": 1,
                                       "method": "initialize",
                                       "params": {"protocolVersion": "2025-03-26"}})
        self.assertEqual(response["result"]["protocolVersion"], "2025-03-26")
        tools = mcp.handle_request({"jsonrpc": "2.0", "id": 2,
                                    "method": "tools/list",
                                    "params": {}})["result"]["tools"]
        self.assertEqual([t["name"] for t in tools],
                         ["scan_directory", "search_github",
                          "generate_rattpkg", "generate_rattspec",
                          "generate_project"])
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            result = mcp.handle_request({"jsonrpc": "2.0", "id": 3,
                                         "method": "tools/call",
                                         "params": {"name": "scan_directory",
                                                    "arguments": {
                                                        "directory": str(
                                                            fixture(Path(directory)))}}})
            payload = json.loads(result["result"]["content"][0]["text"])
            self.assertEqual(payload["suggested_target"], "exe")
        unknown = mcp.handle_request({"jsonrpc": "2.0", "id": 4,
                                      "method": "tools/call",
                                      "params": {"name": "nope",
                                                 "arguments": {}}})
        self.assertTrue(unknown["result"]["isError"])
        self.assertIsNone(mcp.handle_request({"jsonrpc": "2.0",
                                              "method": "notifications/initialized",
                                              "params": {}}))

    def test_generated_rattspec_lints_with_rattsc(self):
        interpreter = ROOT / "build" / ("rattsc.exe" if sys.platform == "win32"
                                        else "rattsc")
        if not interpreter.exists():
            self.skipTest("build rattsc first")
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            root = fixture(Path(directory))
            summary = mcp.generate_project(root, name="demo",
                                           write_rattpkg=False)
            self.assertEqual(summary["rattspec"]["language"], "c")
            result = subprocess.run(
                [str(interpreter), "--lint", str(root / "Rattspec")],
                text=True, capture_output=True, timeout=60)
            self.assertEqual(result.returncode, 0,
                             result.stderr + result.stdout)


if __name__ == "__main__":
    unittest.main()
