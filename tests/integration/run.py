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
import sys
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

        # Package cycles are legal. The newest candidate contradicts the
        # transitive requirements, so SAT must select the older cycle.
        for name, version, deps in [
                ("cycle-a", "1.0.0", 'dep "cycle-b" from: registry, version: "^1.0"'),
                ("cycle-a", "2.0.0", 'dep "cycle-b" from: registry, version: "^1.0"; '
                 'dep "orphan" from: registry, version: "*"'),
                ("cycle-b", "1.0.0", 'dep "cycle-a" from: registry, version: "^1.0"'),
                ("orphan", "1.0.0", 'dep "orphan" from: registry, version: "*"')]:
            package, checksum = archive(server, name, version, "deps { " + deps + " }\n")
            versions.setdefault(name, []).append({"version": version,
                "url": url + "/" + package.name, "sha256": checksum})
        for name in ("cycle-a", "cycle-b", "orphan"):
            put(server, name + "/index.json", json.dumps({"versions": versions[name]}))
        cyclic = work / "cyclic-packages"
        put(cyclic, "Rattpkg", 'package(name: "cycles", version: "1.0.0")\n'
            'deps { dep "cycle-a" from: registry, version: "*" }')
        run([BUILD / "rattpkg", "resolve", "-C", cyclic])
        lock = (cyclic / "Rattpkg.lock").read_bytes()
        entries = tomllib.loads(lock.decode())["package"]
        assert {p["name"]: p["version"] for p in entries} == {
            "cycle-a": "1.0.0", "cycle-b": "1.0.0"}
        run([BUILD / "rattpkg", "verify", "-C", cyclic])
        run([BUILD / "rattpkg", "resolve", "-C", cyclic])
        assert (cyclic / "Rattpkg.lock").read_bytes() == lock
        put(cyclic, "Rattpkg", 'package(name: "cycles", version: "1.0.0")\n'
            'deps { dep "cycle-a" from: registry, version: "^2.0" }')
        assert "E_PACKAGE" in run([BUILD / "rattpkg", "resolve", "-C", cyclic], ok=False).stdout
        assert (cyclic / "Rattpkg.lock").read_bytes() == lock
        check("SAT resolves compatible package cycles and rejects contradictory cycles atomically")

        # Two independently valid packages can require different immutable
        # snapshots of the same Git dependency. Exclusion must apply to sources
        # and revisions as well as registry version numbers.
        head = run(["git", "-C", remote, "rev-parse", "HEAD"]).stdout.strip()
        pins = []
        for name, pin in [("pin-left", 'tag: "v1"'), ("pin-right", f'rev: "{head}"')]:
            package, checksum = archive(server, name, deps=
                f'deps {{ dep "raw" from: git("{remote}"), {pin} }}\n')
            pins.append(f'dep "{name}" from: http("{url}/{package.name}"), sha256: "{checksum}"')
        conflicting = work / "conflicting-git-pins"
        put(conflicting, "Rattpkg", 'package(name: "pins", version: "1.0.0")\ndeps { '
            + "; ".join(pins) + " }")
        error = run([BUILD / "rattpkg", "resolve", "-C", conflicting], ok=False).stdout
        assert "E_PACKAGE" in error and "no compatible resolution" in error, error
        assert not (conflicting / "Rattpkg.lock").exists()
        check("SAT rejects conflicting transitive Git revisions")

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


def test_distribution(work):
    prefix = work / "installed tools with spaces"
    run([sys.executable, ROOT / "tools/install.py", "--prefix", prefix, "--with-plugins"])
    installed = prefix / "bin"
    for app in ("rattbuild", "rattpkg", "rattsc", "rattspec", "ratt-language-server"):
        assert "0.1.0" in run([installed / app, "--version"], cwd=work).stdout
    assert "42" in run([installed / "rattsc", "-e", "print(6 * 7)"], cwd=work).stdout
    cyclic = work / "installed-cycle"
    spec(cyclic, 'project(name: "cycle", version: "1", kind: "single")\n'
         'rule(name: "a", output: "out/a", deps: ["b"], command: ["true"])\n'
         'rule(name: "b", output: "out/b", deps: ["a"], command: ["true"])\n')
    error = run([installed / "rattbuild", "graph", "-C", cyclic], cwd=work, ok=False).stdout
    assert "E_CYCLE" in error and "Satie suggests reviewing dependency b -> a" in error, error
    assert (prefix / "share/rattpack/templates/scaffold/Rattpkg.in").is_file()
    assert (prefix / "share/rattpack/addons/neovim/ratt-languages/lua/ratt/init.lua").is_file()
    assert (prefix / "share/rattpack/addons/sublime/plugin.py").is_file()
    # Exercise spaces in paths while keeping generated package names valid.
    scaffolds = work / "starter projects with spaces"
    for profile in ("c-exe", "c-lib", "cxx-exe", "cxx-lib", "d-exe", "d-lib", "empty", "monorepo"):
        project = scaffolds / (profile + "-starter")
        run([installed / "rattbuild", "--init", "--scaffold", "--profile=" + profile, "-C", project])
        run([installed / "rattbuild", "build", "--warnings-as-errors", "-C", project, "-j", "2"])
        assert "0 built" in run([installed / "rattbuild", "build", "-C", project]).stdout
        run([installed / "rattpkg", "resolve", "-C", project])
        run([installed / "rattpkg", "verify", "-C", project])
        if profile.endswith("-exe"):
            assert run([project / "build" / project.name]).stdout == "Hello from Rattpack!\n"
    project = scaffolds / "c-exe-starter"
    destination = work / "installed-plugin-export"
    run([installed / "rattbuild", "export", "-C", project, "--to=" + str(installed / "plugins/ninja.so"), "-o", destination])
    run(["ninja", "-C", destination])
    check("installed CLIs, runtime and plugin work outside checkout; all eight scaffolds build")


def assist_stub(work, response, log):
    """A stub OpenCode V2 CLI: rattspec uses the CLI for IPC and auth."""
    script = work / ("fake opencode " + log.name)
    script.write_text("#!/bin/sh\nprintf '%s\\n' \"$@\" > " + str(log) + "\ncat <<'RESPONSE'\n"
                      + response + "\nRESPONSE\n")
    script.chmod(0o755)
    return script


def test_assist(work):
    log = work / "argv.txt"
    spec_text = json.dumps("project(name: \"assist demo\", version: \"1.0.0\", kind: \"single\")\n"
                           "import \"target\"\n"
                           "target.executable(name: \"demo\", language: \"c\", sources: [\"main.c\"])\n")
    manifest_text = json.dumps("package(name: \"assist-demo\", version: \"1.0.0\")\ndeps {\n"
                               "  dep \"fmt\" from: git(\"https://example.org/fmt.git\"), tag: \"11.0.2\"\n}\n")
    proposal = json.dumps({"files": {"Rattspec": json.loads(spec_text), "Rattpkg": json.loads(manifest_text)},
                           "summary": "Added a C executable and pinned fmt."})
    response = json.dumps({"data": {"text": proposal}})
    stub = assist_stub(work, response, log)

    project = work / "assist project"
    put(project, "main.c", "int main(void) { return 0; }\n")
    preview = run([BUILD / "rattspec", "assist", "add fmt and an executable", "-C",
                   project, "--opencode", "--opencode-executable", stub, "--dry-run"]).stdout
    assert '"Rattspec"' in preview and not (project / "Rattspec").exists()
    argv = log.read_text().splitlines()
    assert argv[0] == "api" and argv[1] == "post"
    assert argv[2] == "/api/experimental/generate"
    assert json.loads(argv[4])["prompt"].endswith('"add fmt and an executable"}')

    run([BUILD / "rattspec", "assist", "add fmt and an executable", "-C", project,
         "--opencode", "--opencode-executable", stub])
    assert "Added a C executable and pinned fmt." in run(
        [BUILD / "rattspec", "assist", "add fmt and an executable", "-C", project,
         "--opencode", "--opencode-executable", stub]).stdout
    assert not (project / "Rattpkg.lock").exists()
    run([BUILD / "rattbuild", "build", "--warnings-as-errors", "-C", project])
    assert (project / "build/demo").exists()

    # The model reference and explicit server reach the CLI unchanged, and the
    # request runs on a private OpenCode server by default.
    run([BUILD / "rattspec", "assist", "again", "-C", project, "--opencode", "--opencode-executable", stub,
         "--model", "opencode-go/space-bunny-free#free", "--server", "http://127.0.0.1:4096"])
    argv = log.read_text().splitlines()
    assert json.loads(argv[4])["model"] == {"providerID": "opencode-go",
                                            "id": "space-bunny-free", "variant": "free"}
    joined = argv
    server = joined.index("--server")
    assert joined[server + 1] == "http://127.0.0.1:4096", joined
    assert "--standalone" in joined
    run([BUILD / "rattspec", "assist", "again", "-C", project, "--opencode", "--opencode-executable", stub,
         "--no-standalone"])
    assert "--standalone" not in log.read_text().splitlines()

    # A proposal the host cannot accept is never written.
    broken = assist_stub(work, json.dumps({"data": {"text": json.dumps(
        {"files": {"Rattpkg": "package(name: \"assist-demo\", version: \"1.0.0\")\ndeps {\n"
                  "  dep \"fmt\" from: git(\"https://example.org/fmt.git\")\n}\n"},
         "summary": "unpinned"})}}), work / "broken.txt")
    before = (project / "Rattpkg").read_text()
    assert "E_ASSIST" in run([BUILD / "rattspec", "assist", "x", "-C", project,
                              "--opencode", "--opencode-executable", broken], ok=False).stdout
    assert (project / "Rattpkg").read_text() == before
    assert "E_ASSIST" in run([BUILD / "rattspec", "assist", "x", "-C", project,
                              "--opencode", "--opencode-executable", str(work / "missing opencode")], ok=False).stdout
    check("rattspec assist drives OpenCode IPC on a private server, publishes validated files, and fails closed")


def test_map_and_openai(work):
    tree = work / "mapped tree"
    put(tree, "main.c", "int main(void) { return 0; }\n")
    put(tree, "src/util.c", "int f(void) { return 1; }\n")
    put(tree, "src/util.h", "int f(void);\n")
    put(tree, ".git/config", "ignored\n")
    put(tree, "build/out.o", "generated\n")
    put(tree, "run.sh", "#!/bin/sh\n")
    (tree / "run.sh").chmod(0o755)
    cache = Path(environment["XDG_CACHE_HOME"]) / "rattpack" / "mapped tree.bin"
    result = run([BUILD / "rattspec", "map", tree, "--print"]).stdout
    assert cache.is_file(), result
    text = result.splitlines()
    # Version control metadata and build output are never mapped.
    assert not any(".git" in line or "out.o" in line for line in text), result
    assert any(line.strip().startswith("f run.sh") and ":X:" in line for line in text), result
    assert any(line.strip().startswith("d src:") for line in text), result
    # The map attaches to assist prompts, so a second scan must be byte-identical.
    again = run([BUILD / "rattspec", "map", tree, "--print"]).stdout
    assert again == result
    # A missing directory is a diagnostic, not a crash.
    assert "E_MAP" in run([BUILD / "rattspec", "map", work / "absent"], ok=False).stdout

    # Any OpenAI-compatible server: a stub answers both endpoint families.
    seen = work / "openai-seen.json"

    class OpenAiHandler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            seen.write_text(json.dumps({"path": self.path, "auth": self.headers.get("Authorization"),
                                        "body": payload}))
            files = {"Rattspec": "project(name: \"ai demo\", version: \"1.0.0\", kind: \"single\")\n"
                                 "import \"target\"\n"
                                 "target.executable(name: \"demo\", language: \"c\", sources: [\"main.c\"])\n",
                     "Rattpkg": "package(name: \"ai-demo\", version: \"1.0.0\")\n"}
            text = json.dumps({"files": files, "summary": "stubbed"})
            if "input" in payload:
                reply = json.dumps({"output_text": text})
            else:
                reply = json.dumps({"choices": [{"message": {"content": text}}]})
            data = reply.encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    class OpenAiServer(socketserver.ThreadingTCPServer):
        daemon_threads = True
        allow_reuse_address = True

    server = OpenAiServer(("127.0.0.1", 0), OpenAiHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        url = "http://127.0.0.1:%d/v1" % server.server_address[1]
        project = work / "ai project"
        put(project, "main.c", "int main(void) { return 0; }\n")
        run([BUILD / "rattspec", "map", project])
        # A bearer key and the chat endpoint family.
        run([BUILD / "rattspec", "assist", "add a target", "-C", project, "--openai",
             "--openai-url", url, "--openai-key", "sk-test", "--model", "stub-model"])
        request = json.loads(seen.read_text())
        assert request["path"] == "/v1/chat/completions", request
        assert request["auth"] == "Bearer sk-test", request
        assert request["body"]["model"] == "stub-model", request
        assert "Project map" in request["body"]["messages"][0]["content"], request
        run([BUILD / "rattbuild", "build", "--warnings-as-errors", "-C", project])
        assert (project / "build/demo").exists()
        # Basic credentials take precedence over the key.
        run([BUILD / "rattspec", "assist", "again", "-C", project, "--openai",
             "--openai-url", url, "--openai-user", "alice", "--openai-password", "s3cret",
             "--model", "stub-model", "--dry-run"])
        request = json.loads(seen.read_text())
        assert request["auth"] == "Basic YWxpY2U6czNjcmV0", request
        # The responses endpoint family and a config-driven backend.
        run([BUILD / "rattspec", "assist", "again", "-C", project, "--openai",
             "--openai-url", url, "--openai-key", "sk-test", "--model", "stub-model",
             "--openai-api", "responses", "--dry-run"])
        assert json.loads(seen.read_text())["path"] == "/v1/responses"
        config = Path(environment["XDG_CONFIG_HOME"]) / "rattpack"
        config.mkdir(parents=True, exist_ok=True)
        (config / "Rattpack.json").write_text(json.dumps({
            "backend": "openai",
            "openai": {"base_url": url, "api_key": "sk-config", "model": "config-model"}}))
        environment.pop("OPENAI_API_KEY", None)
        environment.pop("OPENAI_BASE", None)
        environment.pop("OPENAI_MODEL", None)
        run([BUILD / "rattspec", "assist", "from config", "-C", project, "--dry-run"])
        request = json.loads(seen.read_text())
        assert request["auth"] == "Bearer sk-config", request
        assert request["body"]["model"] == "config-model", request
        (config / "Rattpack.json").unlink()
        # Missing credentials are rejected before any request is made.
        assert "E_ASSIST" in run([BUILD / "rattspec", "assist", "x", "-C", project, "--openai",
                                  "--openai-url", url, "--model", "stub-model",
                                  "--dry-run"], ok=False).stdout
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    check("rattspec map caches and renders a terse directory map reused by assist prompts")
    check("rattspec assist --openai drives both OpenAI endpoint families and credential modes")


def test_parallel_and_hermetic(work):
    script = '''import json, pathlib, time
import sys
start = time.monotonic_ns()
time.sleep(0.15)
pathlib.Path(sys.argv[1]).write_text(json.dumps([start, time.monotonic_ns()]))
'''
    for jobs in (1, 2, 4):
        project = work / ("jobs-" + str(jobs))
        source = 'project(name: "jobs", version: "1", kind: "single")\n'
        for i in range(6):
            argv = json.dumps([sys.executable, "-c", script, "build/" + str(i)])
            source += f'rule(name: "job{i}", output: "build/{i}", command: {argv})\n'
        spec(project, source)
        run([BUILD / "rattbuild", "build", "-C", project, "-j", str(jobs)])
        events = []
        for i in range(6):
            start, end = json.loads((project / "build" / str(i)).read_text())
            events.extend([(start, 1), (end, -1)])
        active = peak = 0
        for _, delta in sorted(events):
            active += delta
            peak = max(peak, active)
        assert peak == jobs, (jobs, peak)
    check("CLI -j 1, 2 and 4 bounds actual concurrent process actions")

    project = work / "hermetic"
    put(project, "input", "frozen input")
    put(project, "secret", "undeclared")
    spec(project, '''project(name: "strict", version: "1", kind: "single")
import "fs"
import "proc"
let t = rule(name: "t", inputs: ["input"], output: "build/t", env: {DECLARED: "frozen"})
action(t) { fs.write("build/t", fs.read("input") + proc.env("DECLARED") + proc.env("RATTPACK_INTEGRATION_LEAK", "absent")) }
''')
    frozen = put(work, "strict.json", run([BUILD / "rattbuild", "graph", "--hermetic", "-C", project]).stdout)
    environment["RATTPACK_INTEGRATION_LEAK"] = "ambient"
    (project / "Rattspec").unlink()
    config = Path(environment["XDG_CONFIG_HOME"]) / "rattpack/Config.toml"
    config.write_text("[invalid config")
    run([BUILD / "rattbuild", "build", "--import", frozen, "-j", "2"])
    assert (project / "build/t").read_text() == "frozen inputfrozenabsent"
    put(project, "input", "changed")
    assert "E_HERMETIC" in run([BUILD / "rattbuild", "build", "--import", frozen], ok=False).stdout
    config.unlink()
    environment.pop("RATTPACK_INTEGRATION_LEAK")
    check("frozen hermetic graph ignores ambient config/environment and rejects changed sources")

    project = work / "isolated-process"
    source = '''import pathlib, socket
try:
    pathlib.Path("secret").read_text()
except FileNotFoundError:
    pass
else:
    raise AssertionError("undeclared file was visible")
sock = socket.socket()
sock.settimeout(0.2)
try:
    sock.connect(("127.0.0.1", 9))
except OSError:
    pass
else:
    raise AssertionError("network connection succeeded")
pathlib.Path("build/result").write_text("isolated")
'''
    put(project, "secret", "undeclared")
    spec(project, 'project(name: "isolation", version: "1", kind: "single")\n'
         + 'rule(name: "isolate", output: "build/result", command: '
         + json.dumps([sys.executable, "-c", source]) + ")\n")
    result = subprocess.run([str(BUILD / "rattbuild"), "build", "--hermetic", "-C", str(project)],
                            env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
    if result.returncode:
        assert "E_HERMETIC" in result.stdout, result.stdout
        assert not (project / "build/result").exists()
        check("strict subprocess isolation fails closed when OS isolation is unavailable")
    else:
        assert (project / "build/result").read_text() == "isolated"
        check("strict subprocess isolation hides undeclared files and disables network")


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
        test_distribution(work)
        test_assist(work)
        test_map_and_openai(work)
        test_parallel_and_hermetic(work)
        test_packages(work)
    print(f"{count} integration scenarios passed")


if __name__ == "__main__":
    main()
