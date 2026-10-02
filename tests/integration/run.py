#!/usr/bin/env python3
"""End-to-end tests with real toolchains and loopback HTTP/FTP servers."""
from contextlib import contextmanager
import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import shutil
import socket
import socketserver
import subprocess
import tarfile
import tempfile
import threading
import tomllib
import zipfile

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "build"
environment = os.environ.copy()
count = 0


def run(argv, cwd=None, ok=True):
    result = subprocess.run([str(a) for a in argv], cwd=cwd, env=environment,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    if ok and result.returncode:
        raise AssertionError(f"command failed: {argv}\n{result.stdout}")
    if not ok and not result.returncode:
        raise AssertionError(f"command unexpectedly succeeded: {argv}\n{result.stdout}")
    return result


def check(name):
    global count
    count += 1
    print("PASS", name, flush=True)


def put(root, path, text):
    file = root / path
    file.parent.mkdir(parents=True, exist_ok=True)
    file.write_text(text)
    return file


def fixture(work, name, destination=None):
    destination = work / (destination or name)
    shutil.copytree(ROOT / "tests/integration/fixtures" / name, destination,
                    ignore=shutil.ignore_patterns("build", ".rattpack"))
    return destination


def spec(root, text):
    return put(root, "Rattspec", text)


def test_builds(work):
    project = fixture(work, "basic", "C project with spaces")
    result = run([BUILD / "rattbuild", "build", "-C", project, "-j", "4"])
    assert "1 built" in result.stdout
    assert run([project / "build/hello"]).stdout == "hello from Rattpack\n"
    assert "0 built, 1 up to date" in run([BUILD / "rattbuild", "build", "-C", project]).stdout
    (project / "build/hello").write_text("tampered")
    assert "1 built" in run([BUILD / "rattbuild", "build", "-C", project]).stdout
    check("native C compilation, spaces, incrementality, and output verification")

    actions = fixture(work, "actions")
    graph = run([BUILD / "rattbuild", "graph", "--dot", "-C", actions]).stdout
    assert not (actions / "build/message.txt").exists()
    dot = put(work, "actions.dot", graph)
    original = run([BUILD / "rattbuild", "graph", "-C", actions]).stdout
    imported = run([BUILD / "rattbuild", "graph", "--import", dot]).stdout
    assert json.loads(original) == json.loads(imported)
    run([BUILD / "rattbuild", "build", "--import", dot])
    assert (actions / "build/copy.txt").read_text() == "deferred!\n"
    assert "0 built, 2 up to date" in run([BUILD / "rattbuild", "build", "-C", actions]).stdout
    check("pure construction, frozen closures, dependent artifacts, and DOT round trip")

    languages = work / "languages"
    put(languages, "value.c", "int value(void) { return 42; }\n")
    put(languages, "main.cpp", 'extern "C" int value(void); int main() { return value() == 42 ? 0 : 1; }\n')
    put(languages, "main.d", 'import std.stdio; void main() { writeln("D works"); }\n')
    spec(languages, '''project(name: "languages", version: "1.0.0", kind: "single")
import "target"
let lib = target.library(name: "value", sources: ["value.c"], language: "c")
target.executable(name: "cxx", sources: ["main.cpp"], language: "cxx", deps: [lib])
target.executable(name: "d", sources: ["main.d"], language: "d")
''')
    run([BUILD / "rattbuild", "build", "-C", languages, "-j", "4"])
    run([languages / "build/cxx"])
    assert run([languages / "build/d"]).stdout == "D works\n"
    check("C static libraries, C++ linking, and D targets")

    sandbox = work / "sandbox"
    spec(sandbox, '''project(name: "sandbox", version: "1", kind: "single")
import "fs"
let t = rule(name: "t", output: "build/out")
action(t) { fs.write("outside", "blocked") }
''')
    result = run([BUILD / "rattbuild", "build", "-C", sandbox], ok=False)
    assert "E_ACTION" in result.stdout and not (sandbox / "outside").exists()
    (sandbox / "Rattspec").write_text((sandbox / "Rattspec").read_text().replace('"outside"', '"build/../outside"'))
    result = run([BUILD / "rattbuild", "build", "-C", sandbox], ok=False)
    assert "E_ACTION" in result.stdout and not (sandbox / "outside").exists()
    check("action filesystem write scopes")

    templates = work / "templates"
    put(templates, "main.c.in", 'int main(void) { return @{20 + 22} == 42 ? 0 : 1; }\n')
    put(templates, "settings.h.in", '#define ANSWER @{6 * 7}\n')
    spec(templates, '''project(name: "templates", version: "1", kind: "single")
import "target"
target.executable(name: "configured", sources: ["main.c.in"], headers: ["settings.h.in"])
''')
    run([BUILD / "rattbuild", "graph", "-C", templates])
    assert not (templates / "main.c").exists()
    run([BUILD / "rattbuild", "build", "-C", templates])
    assert "#define ANSWER 42" in (templates / "settings.h").read_text()
    run([templates / "build/configured"])
    check("source/header templates are configured only during graph execution")

    script_templates = work / "script templates"
    put(script_templates, "helper.ratt.in", 'fn answer() -> int { return @{6 * 7} }\n')
    put(script_templates, "content.in", '@{20 + 22}\n')
    put(script_templates, "Rattspec.in", '''project(name: "@{dirname}", version: "1", kind: "single")
import "fs"
import "./helper.ratt.in"
let t = rule(name: "t", output: "build/result", raw_inputs: ["content.in"])
action(t) { fs.write("build/result", str(helper.answer()) + ":" + fs.read("content.in")) }
''')
    run([BUILD / "rattbuild", "build", "-C", script_templates])
    assert (script_templates / "build/result").read_text() == "42:42\n"
    check("preprocessed root specs, script imports, and filesystem reads")


def test_exporters(work):
    config = Path(environment["XDG_CONFIG_HOME"]) / "rattpack/Config.toml"
    config.parent.mkdir(parents=True, exist_ok=True)
    for exporter in ("cmake", "gnumake", "ninja", "meson"):
        config.write_text('[user]\nname = "Frozen Name"\n')
        project = fixture(work, "actions", "export " + exporter)
        put(project, "content.in", '@{env.get("user.name")}\n')
        with (project / "Rattspec").open("a") as source:
            source.write('''\nlet settings = rule(name: "settings", output: "build/settings.txt", raw_inputs: ["content.in"])
action(settings) { fs.write("build/settings.txt", fs.read("content.in")) }
''')
        destination = project / "export files"
        run([BUILD / "rattbuild", "export", "--to=" + exporter, "-C", project, "-o", destination])
        # Removing the original specs proves exporters and action runners use
        # only the frozen DAG, including its already-captured lexical scopes.
        (project / "Rattspec").unlink()
        # The action runner must use captured settings even if the config has
        # been replaced by an invalid file since export.
        config.write_text("[invalid configuration")
        if exporter == "cmake":
            run(["cmake", "-S", destination, "-B", destination / "cmake-build"])
            command = ["cmake", "--build", destination / "cmake-build", "-j", "4"]
        elif exporter == "gnumake":
            command = ["make", "-C", destination, "-j", "4"]
        elif exporter == "ninja":
            command = ["ninja", "-C", destination, "-j", "4"]
        else:
            run(["meson", "setup", destination / "meson-build", destination])
            command = ["meson", "compile", "-C", destination / "meson-build", "-j", "4"]
        run(command)
        assert (project / "build/copy.txt").read_text() == "deferred!\n"
        assert (project / "build/settings.txt").read_text() == "Frozen Name\n"
        before = (project / "build/copy.txt").stat().st_mtime_ns
        run(command)
        assert before == (project / "build/copy.txt").stat().st_mtime_ns
        check(exporter + " exporter executes frozen graph and stays incremental")
    config.unlink()

    project = fixture(work, "basic", "plugin")
    run([BUILD / "rattbuild", "export", "--to=" + str(BUILD / "plugins/ninja.so"),
         "-C", project, "-o", project / "export"])
    run(["ninja", "-C", project / "export"])
    assert run([project / "build/hello"]).stdout == "hello from Rattpack\n"
    check("dynamically loaded D-ABI exporter")


def test_profiles_and_identity(work):
    project = work / "init"
    project.mkdir()
    names = run([BUILD / "rattbuild", "--init", "--list-profiles"]).stdout.splitlines()
    assert set(names) == {"c-exe", "c-lib", "cxx-exe", "cxx-lib", "d-exe", "d-lib", "monorepo", "empty"}
    run([BUILD / "rattbuild", "--init", "-C", project])
    run([BUILD / "rattbuild", "build", "-C", project])
    assert (project / "build/welcome.txt").read_text() == "init\n"
    run([BUILD / "rattbuild", "--init", "-C", project], ok=False)
    profile = Path(environment["XDG_CONFIG_HOME"]) / "rattpack/buildprof/custom.in"
    profile.write_text('project(name: "@{env.get(\"user.name\")}", version: "1", kind: "single")\n'
                       'import "fs"\nlet x = rule(name: "x", output: "build/x")\n'
                       'action(x) { fs.write("build/x", "configured") }\n')
    config = profile.parents[1] / "Config.toml"
    config.write_text('[user]\nname = "Configured User"\n')
    custom = work / "custom-init"
    custom.mkdir()
    run([BUILD / "rattbuild", "--init", "--profile=custom", "-C", custom])
    assert 'name: "Configured User"' in (custom / "Rattspec").read_text()
    check("shipped and user profiles, config substitution, and initialization")

    mono = work / "monorepo"
    spec(mono, '''project(name: "root", version: "1", kind: "monorepo")
monorepo { member "one"; vendored "two"; ignore "ignored" }
import "fs"
let root = rule(name: "root", output: "build/root")
action(root) { fs.write("build/root", "root") }
''')
    for name in ("one", "two"):
        spec(mono / name, f'''project(name: "{name}", version: "1", kind: "single")
import "fs"
let t = rule(name: "same", output: "build/same")
action(t) {{ fs.write("build/same", "{name}") }}
''')
    spec(mono / "ignored", "this is intentionally invalid")
    run([BUILD / "rattbuild", "build", "--warnings-as-errors", "-C", mono, "-j", "4"])
    assert (mono / "one/build/same").read_text() == "one"
    assert (mono / "two/build/same").read_text() == "two"
    (mono / "Rattspec").write_text((mono / "Rattspec").read_text().replace('member "one";', ""))
    assert "W_UNDECLARED_NESTED_SPEC" in run([BUILD / "rattbuild", "graph", "--warnings-as-errors", "-C", mono], ok=False).stdout
    check("isolated monorepo identities, parallel members, ignored projects, and CI warning promotion")


class QuietHTTP(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


@contextmanager
def http_server(directory):
    handler = lambda *args, **kwargs: QuietHTTP(*args, directory=str(directory), **kwargs)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


@contextmanager
def ftp_server(directory):
    """Small passive FTP fixture; it implements only read-only file retrieval."""
    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            passive = None

            def reply(text):
                self.wfile.write((text + "\r\n").encode())
                self.wfile.flush()

            reply("220 Rattpack test FTP")
            try:
                while line := self.rfile.readline():
                    command, _, argument = line.decode().strip().partition(" ")
                    path = directory / Path(argument).name
                    if command == "USER":
                        reply("331 Password required")
                    elif command == "PASS":
                        reply("230 Logged in")
                    elif command == "PWD":
                        reply('257 "/"')
                    elif command in ("CWD", "TYPE"):
                        reply("200 OK")
                    elif command == "SIZE" and path.is_file():
                        reply("213 " + str(path.stat().st_size))
                    elif command == "PASV":
                        if passive:
                            passive.close()
                        passive = socket.socket()
                        passive.bind(("127.0.0.1", 0))
                        passive.listen(1)
                        passive.settimeout(10)
                        port = passive.getsockname()[1]
                        reply(f"227 Entering Passive Mode (127,0,0,1,{port // 256},{port % 256})")
                    elif command == "RETR" and path.is_file() and passive:
                        reply("150 Opening data connection")
                        data, _ = passive.accept()
                        with data:
                            data.sendall(path.read_bytes())
                        passive.close()
                        passive = None
                        reply("226 Transfer complete")
                    elif command == "QUIT":
                        reply("221 Goodbye")
                        break
                    else:
                        reply("550 Unsupported operation")
            finally:
                if passive:
                    passive.close()

    class Server(socketserver.ThreadingTCPServer):
        daemon_threads = True

    server = Server(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"ftp://127.0.0.1:{server.server_address[1]}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def archive(server, name, version="1.0.0", deps="", compression="gz"):
    path = server / (name + "-" + version + ".tar." + compression)
    with tarfile.open(path, "w:" + compression) as output:
        files = {"Rattpkg": f'package(name: "{name}", version: "{version}")\n' + deps,
                 "data.txt": name + " " + version}
        for name_, text in files.items():
            data = text.encode()
            info = tarfile.TarInfo("package/" + name_)
            info.size = len(data)
            info.mode = 0o644
            output.addfile(info, io.BytesIO(data))
    return path, hashlib.sha256(path.read_bytes()).hexdigest()


def test_packages(work):
    remote = work / "git-remote"
    remote.mkdir()
    run(["git", "init", "-b", "main", remote])
    put(remote, "data.txt", "original")
    run(["git", "-C", remote, "add", "."])
    run(["git", "-C", remote, "-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-m", "fixture"])
    run(["git", "-C", remote, "tag", "v1"])
    project = work / "git-packages"
    put(project, "Rattpkg", f'package(name: "app", version: "1.0.0")\ndeps {{ dep "raw" from: git("{remote}"), tag: "v1" }}\n')
    run([BUILD / "rattpkg", "resolve", "-C", project])
    lock = tomllib.loads((project / "Rattpkg.lock").read_text())
    entry = lock["package"][0]
    assert entry["identity"] == "source" and len(entry["revision"]) == 40
    path = Path(environment["XDG_CACHE_HOME"]) / "rattpack/pkgs/raw" / entry["tree_hash"]
    assert (path / "data.txt").read_text() == "original"
    run([BUILD / "rattpkg", "verify", "-C", project])
    before = (project / "Rattpkg.lock").read_bytes()
    run([BUILD / "rattpkg", "resolve", "-C", project])
    assert (project / "Rattpkg.lock").read_bytes() == before
    (path / "data.txt").write_text("tampered")
    assert "E_CHECKSUM" in run([BUILD / "rattpkg", "verify", "-C", project], ok=False).stdout
    shutil.rmtree(path)
    put(remote, "data.txt", "changed head")
    run(["git", "-C", remote, "add", "."])
    run(["git", "-C", remote, "-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-m", "advance"])
    run([BUILD / "rattpkg", "fetch", "-C", project])
    assert (path / "data.txt").read_text() == "original"
    floating = work / "floating"
    put(floating, "Rattpkg", f'package(name: "floating", version: "1")\ndeps {{ dep "raw" from: git("{remote}"), branch: "main" }}\n')
    assert "E_FLOATING" in run([BUILD / "rattpkg", "resolve", "-C", floating], ok=False).stdout
    run([BUILD / "rattpkg", "resolve", "--allow-floating", "-C", floating])
    check("raw Git remotes, pinned revisions, deterministic lock reuse, floating opt-in, and tamper detection")

    mono = work / "member packages"
    spec(mono, '''project(name: "packages", version: "1", kind: "monorepo")
monorepo { member "member" }
import "fs"
let t = rule(name: "root", output: "build/root")
action(t) { fs.write("build/root", "root") }
''')
    spec(mono / "member", '''project(name: "member", version: "1", kind: "single")
import "pkg"
import "fs"
import "path"
let raw = pkg.get("raw")
let t = rule(name: "dependency", output: "build/data")
action(t) { fs.write("build/data", fs.read(path.join(raw.path, "data.txt"))) }
''')
    shutil.copyfile(project / "Rattpkg.lock", mono / "member/Rattpkg.lock")
    # There is no root lockfile; subordinate modules inherit their member's lock.
    put(mono, "member/sub/Rattspec.m", '''module(name: "sub")
import "pkg"
import "fs"
import "path"
let raw = pkg.get("raw")
let t = rule(name: "dependency", output: "build/data")
action(t) { fs.write("build/data", fs.read(path.join(raw.path, "data.txt"))) }
''')
    run([BUILD / "rattbuild", "build", "--warnings-as-errors", "-C", mono])
    assert (mono / "member/build/data").read_text() == "original"
    assert (mono / "member/sub/build/data").read_text() == "original"
    check("monorepo members and subordinate modules use member-specific package locks")

    put(remote, "Rattspec", 'project(name: "synthesized", version: "2.3.4", kind: "single")\n')
    run(["git", "-C", remote, "add", "."])
    run(["git", "-C", remote, "-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-m", "project identity"])
    run(["git", "-C", remote, "tag", "v2"])
    synthetic = work / "synthesized"
    put(synthetic, "Rattpkg", f'package(name: "synthetic", version: "1")\ndeps {{ dep "project" from: git("{remote}"), tag: "v2" }}\n')
    run([BUILD / "rattpkg", "resolve", "-C", synthetic])
    entry = tomllib.loads((synthetic / "Rattpkg.lock").read_text())["package"][0]
    assert entry["identity"] == "project" and entry["version"] == "2.3.4"
    check("Git projects without manifests synthesize package identity from Rattspec")

    server = work / "server"
    server.mkdir()
    with http_server(server) as url:
        gzip, gz_hash = archive(server, "gzip")
        xz, xz_hash = archive(server, "xz", compression="xz")
        project = work / "archives"
        put(project, "Rattpkg", f'''package(name: "archives", version: "1")
deps {{
 dep "gzip" from: http("{url}/{gzip.name}"), sha256: "{gz_hash}"
 dep "xz" from: http("{url}/{xz.name}"), sha256: "{xz_hash}"
}}
''')
        run([BUILD / "rattpkg", "resolve", "-C", project])
        run([BUILD / "rattpkg", "verify", "-C", project])
        bad = work / "bad-checksum"
        put(bad, "Rattpkg", f'package(name: "bad", version: "1")\ndeps {{ dep "bad" from: http("{url}/{gzip.name}"), sha256: "{"0" * 64}" }}')
        assert "E_CHECKSUM" in run([BUILD / "rattpkg", "resolve", "-C", bad], ok=False).stdout
        check("HTTP archive fetching, gzip/xz extraction, and mandatory SHA-256 verification")

        versions = {}
        for name, version, dependency in [("z", "1.0.0", ""), ("z", "2.0.0", ""),
                ("a", "1.0.0", '^1.0'), ("a", "1.1.0", '^2.0'), ("b", "1.0.0", '^1.0')]:
            deps = f'deps {{ dep "z" from: registry, version: "{dependency}" }}\n' if dependency else ""
            package, checksum = archive(server, name, version, deps)
            versions.setdefault(name, []).append({"version": version, "url": url + "/" + package.name, "sha256": checksum})
        for name, entries in versions.items():
            put(server, name + "/index.json", json.dumps({"versions": entries}))
        config = Path(environment["XDG_CONFIG_HOME"]) / "rattpack/Config.toml"
        config.write_text(f'[pkg]\nregistry = "{url}"\n')
        project = work / "registry"
        put(project, "Rattpkg", 'package(name: "registry", version: "1")\ndeps { dep "a" from: registry, version: "^1.0"; dep "b" from: registry, version: "^1.0" }')
        run([BUILD / "rattpkg", "resolve", "-C", project])
        selected = {p["name"]: p["version"] for p in tomllib.loads((project / "Rattpkg.lock").read_text())["package"]}
        assert selected == {"a": "1.0.0", "b": "1.0.0", "z": "1.0.0"}, selected
        run([BUILD / "rattpkg", "verify", "-C", project])
        check("registry semantic-version constraints, transitive resolution, and backtracking")

        zipped = server / "zip.zip"
        with zipfile.ZipFile(zipped, "w", zipfile.ZIP_DEFLATED) as output:
            output.writestr("package/Rattpkg", 'package(name: "zip", version: "1.0.0")\n')
            info = zipfile.ZipInfo("package/run.sh")
            info.external_attr = 0o100755 << 16
            output.writestr(info, "#!/bin/sh\nexit 0\n")
        project = work / "zip"
        checksum = hashlib.sha256(zipped.read_bytes()).hexdigest()
        put(project, "Rattpkg", f'package(name: "zip-app", version: "1")\ndeps {{ dep "zip" from: http("{url}/{zipped.name}"), sha256: "{checksum}" }}')
        run([BUILD / "rattpkg", "resolve", "-C", project])
        entry = tomllib.loads((project / "Rattpkg.lock").read_text())["package"][0]
        path = Path(environment["XDG_CACHE_HOME"]) / "rattpack/pkgs/zip" / entry["tree_hash"]
        assert (path / "run.sh").stat().st_mode & 0o111
        (path / "run.sh").chmod(0o644)
        assert "E_CHECKSUM" in run([BUILD / "rattpkg", "verify", "-C", project], ok=False).stdout
        check("ZIP extraction and executable-mode verification")

    with ftp_server(server) as url:
        project = work / "ftp"
        put(project, "Rattpkg", f'package(name: "ftp-app", version: "1")\ndeps {{ dep "gzip" from: ftp("{url}/{gzip.name}"), sha256: "{gz_hash}" }}')
        run([BUILD / "rattpkg", "resolve", "-C", project])
        run([BUILD / "rattpkg", "verify", "-C", project])
        check("FTP retrieval and archive verification")


def main():
    for tool in ("cmake", "ninja", "make", "meson"):
        if not shutil.which(tool):
            raise SystemExit("missing integration tool: " + tool)
    parent = "/tmp/opencode" if Path("/tmp/opencode").is_dir() else None
    with tempfile.TemporaryDirectory(prefix="rattpack-integration-", dir=parent) as directory:
        work = Path(directory)
        environment["XDG_CONFIG_HOME"] = str(work / "config")
        environment["XDG_CACHE_HOME"] = str(work / "cache")
        test_builds(work)
        test_exporters(work)
        test_profiles_and_identity(work)
        test_packages(work)
    print(f"{count} integration scenarios passed")


if __name__ == "__main__":
    main()
