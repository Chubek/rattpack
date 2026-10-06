"""Offline regression tests for GitHub authentication and directory discovery."""
import importlib.util
import io
import itertools
import json
import os
import random
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
TEMP_ROOT = "/tmp/opencode" if Path("/tmp/opencode").is_dir() else None


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tools" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


github = load("github_grep", "github-grep.py")
ls = load("ls2rattpkg", "ls2rattpkg.py")


class RepositoryTools(unittest.TestCase):
    def test_authenticated_search_and_json_results(self):
        response = io.BytesIO(json.dumps({"items": [{"name": "zlib"}]}).encode())
        with patch.dict(os.environ, {"GITHUB_TOKEN": "test-token"}), \
                patch.object(github.urllib.request, "urlopen", return_value=response) as fetch:
            self.assertEqual(github.search_repositories("zlib in:name"), [{"name": "zlib"}])
        request = fetch.call_args.args[0]
        self.assertEqual(request.get_header("Authorization"), "Bearer test-token")
        self.assertNotIn("test-token", request.full_url)
        self.assertIn("zlib+in%3Aname", request.full_url)

    def test_dotenv_does_not_override_environment(self):
        try:
            import dotenv
        except ImportError:
            self.skipTest("install tools/requirements.txt for dotenv tests")
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            path = Path(directory) / ".env"
            path.write_text("GITHUB_TOKEN=from-file\n")
            with patch.dict(os.environ, {}, clear=True):
                github.load_credentials(path)
                self.assertEqual(os.environ["GITHUB_TOKEN"], "from-file")
            with patch.dict(os.environ, {"GITHUB_TOKEN": "from-env"}, clear=True):
                github.load_credentials(path)
                self.assertEqual(os.environ["GITHUB_TOKEN"], "from-env")

    def test_library_files_are_deduplicated_and_directories_preserved(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            root = Path(directory)
            for name in ("libfoo.a", "libfoo.so.2", "libbar.dylib", "readme.txt"):
                (root / name).touch()
            (root / "headers").mkdir()
            (root / ".git").mkdir()
            self.assertEqual(list(ls.libraries(root)), ["headers", "libbar", "libfoo"])

    def test_github_match_is_verified_and_pinned(self):
        mock_github = types.SimpleNamespace(search_repositories=lambda *a, **kw: [
            {"name": "foo-docs", "html_url": "https://github.com/example/foo-docs"},
            {"name": "foo", "clone_url": "https://github.com/example/foo.git"},
        ])
        with patch.object(ls, "remote_revision", return_value="a" * 40) as revision, \
                patch.object(ls, "web_repositories") as web:
            self.assertEqual(ls.discover("foo", Path("/nonexistent"), mock_github),
                             ("https://github.com/example/foo", "a" * 40))
        web.assert_not_called()
        revision.assert_called_once_with("https://github.com/example/foo")

    def test_duckduckgo_fallback_rejects_docs_and_normalizes_gitlab(self):
        mock_github = types.SimpleNamespace(search_repositories=lambda *a, **kw: [])
        client = unittest.mock.Mock()
        client.text.return_value = [
            {"href": "https://example.org/docs"},
            {"href": "https://gitlab.com/group/subgroup/foo/-/tree/main"},
        ]
        with patch.dict(sys.modules, {"ddgs": types.SimpleNamespace(DDGS=lambda: client)}), \
                patch.object(ls, "remote_revision", return_value="b" * 40):
            self.assertEqual(ls.discover("foo", Path("/nonexistent"), mock_github),
                             ("https://gitlab.com/group/subgroup/foo", "b" * 40))
        self.assertEqual(client.text.call_args.kwargs["backend"], "duckduckgo")

    def test_unresolved_output_exit_status_and_no_overwrite(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            root = Path(directory)
            (root / "found").mkdir()
            (root / "missing").mkdir()
            module = types.SimpleNamespace(load_credentials=lambda _: None)
            def discover(name, *args):
                if name == "missing":
                    raise RuntimeError("not found")
                return "https://example.org/found.git", "c" * 40
            argv = ["ls2rattpkg", directory, "--name", "example"]
            with patch.object(sys, "argv", argv), \
                    patch.object(ls, "github_module", return_value=module), \
                    patch.object(ls, "discover", side_effect=discover):
                self.assertEqual(ls.main(), 1)
                text = (root / "Rattpkg").read_text()
                self.assertIn('# Unresolved library: missing', text)
                self.assertIn('rev: "' + "c" * 40 + '"', text)
                with self.assertRaises(SystemExit) as error:
                    ls.main()
                self.assertEqual(error.exception.code, 1)
                self.assertEqual((root / "Rattpkg").read_text(), text)

    def test_revision_is_checked_against_real_git(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            subprocess.run(["git", "init", "-q", directory], check=True)
            subprocess.run(["git", "-C", directory, "-c", "user.name=Test",
                            "-c", "user.email=test@example.org", "commit", "-q",
                            "--allow-empty", "-m", "fixture"], check=True)
            expected = subprocess.check_output(["git", "-C", directory,
                                                "rev-parse", "HEAD"], text=True).strip()
            self.assertEqual(ls.remote_revision(directory), expected)

    def test_solver_preferences_match_exhaustive_models(self):
        helper = ROOT / "build" / ("ratt-satie.exe" if os.name == "nt" else "ratt-satie")
        if not helper.exists():
            self.skipTest("build ratt-satie first")
        rng = random.Random(192)
        for _ in range(40):
            clauses = [[rng.choice((-1, 1)) * rng.randint(1, 5)
                        for _ in range(rng.randint(1, 3))] for _ in range(10)]
            expected = next((values for values in itertools.product((True, False), repeat=5)
                             if all(any(values[abs(v) - 1] == (v > 0) for v in clause)
                                    for clause in clauses)), None)
            result = subprocess.run([str(helper)], input="1 2 3 4 5\n" +
                                    "\n".join(" ".join(map(str, clause)) for clause in clauses) + "\n",
                                    text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            lines = result.stdout.splitlines()
            if expected is None:
                self.assertEqual(lines, ["UNSAT"])
            else:
                self.assertEqual(lines, ["SAT"] + [str(i + 1) for i, v in enumerate(expected) if v])

    def test_generated_manifest_parses_with_rattpack(self):
        interpreter = ROOT / "build" / ("rattsc.exe" if os.name == "nt" else "rattsc")
        if not interpreter.exists():
            self.skipTest("build rattsc first")
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            script = Path(directory) / "generated.ratt"
            # Use the real parser and enforce named arguments with fixture fns.
            script.write_text('fn package(name, version, license) {}\n'
                              'fn git(url) { return url }\n'
                              'fn dep(name, from, rev) { print(name, rev) }\n' +
                              ls.render("example", "1.0.0", "MIT", [
                                  ("foo", "https://example.org/foo.git", "d" * 40)], []))
            result = subprocess.run([str(interpreter), str(script)], text=True,
                                    capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertIn("d" * 40, result.stdout)


if __name__ == "__main__":
    unittest.main()
