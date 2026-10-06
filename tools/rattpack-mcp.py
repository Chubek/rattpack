#!/usr/bin/env python3
"""Rattpack MCP server: scan a directory and generate Rattspec + Rattpkg.

Running with no arguments (or ``--serve``) starts a Model Context Protocol
server on stdio using only the Python standard library. With a directory
argument it performs a one-shot ``generate_project`` and prints the JSON
summary, which is handy for smoke tests.

Tools exposed over MCP:

- ``scan_directory``: inventory source files, libraries, and nested specs.
- ``search_github``: repository search via ``tools/github-grep.py``.
- ``generate_rattpkg``: pinned manifest via ``tools/ls2rattpkg.py`` logic.
- ``generate_rattspec``: build spec from the scanned source layout.
- ``generate_project``: scan once, then write both files with a shared
  project name and version.

MCP client configuration (example for OpenCode ``opencode.json``)::

    {"mcp": {"rattpack": {"type": "local",
      "command": ["python3", "/path/to/rattpack/tools/rattpack-mcp.py"]}}}

Directory scanning and dependency discovery reuse ``ls2rattpkg.py`` so the
MCP server inherits GitHub authentication (``GITHUB_TOKEN`` / ``GH_TOKEN`` /
``GITHUB_API_KEY``, optionally via ``.env``) and the DuckDuckGo fallback.
No extra Python packages are required to run this server itself.
"""

import argparse
import importlib.util
import json
import os
import re
import sys
from pathlib import Path

SERVER_NAME = "rattpack"
SERVER_VERSION = "0.1.0"
# MCP protocol versions this server answers. The newest entry is preferred
# when the client offers something unknown.
PROTOCOL_VERSIONS = ("2024-11-05", "2025-03-26")
DEFAULT_PROTOCOL_VERSION = PROTOCOL_VERSIONS[-1]

HERE = Path(__file__).resolve().parent
SKIP_DIRS = frozenset({
    ".git", ".hg", ".svn", "build", ".rattpack", "__pycache__",
    "node_modules", ".dub", ".vscode", ".idea",
})
SOURCE_EXTS = {
    ".c": "c", ".h": "c",
    ".cpp": "cxx", ".cxx": "cxx", ".cc": "cxx", ".C": "cxx",
    ".hpp": "cxx", ".hh": "cxx", ".hxx": "cxx",
    ".d": "d",
}
SOURCE_FILE_EXTS = (".c", ".cpp", ".cxx", ".cc", ".C", ".d")
MAIN_PATTERNS = {
    "c": re.compile(r"\bint\s+main\s*\("),
    "cxx": re.compile(r"\bint\s+main\s*\("),
    "d": re.compile(r"\b(void|int)\s+main\s*\("),
}
SPEC_NAMES = ("Rattspec", "Rattspec.m", "Rattspec.in")
MAX_MAIN_SCAN_FILES = 100
MAX_MAIN_SCAN_BYTES = 256 * 1024


def _load_sibling(name, filename):
    spec = importlib.util.spec_from_file_location(
        name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def ls2rattpkg_module():
    """Import the sibling generator (patchable in tests)."""
    return _load_sibling("rattpack_ls2rattpkg", "ls2rattpkg.py")


def github_module():
    """Import the sibling GitHub search helper (patchable in tests)."""
    return _load_sibling("rattpack_github_grep", "github-grep.py")


def _error(message):
    return ValueError(message)


def scan_directory(directory, max_files=5000):
    """Inventory a directory for spec and manifest generation."""
    root = Path(directory).expanduser()
    try:
        root = root.resolve(strict=True)
    except OSError:
        raise _error(f"directory not found: {directory}")
    if not root.is_dir():
        raise _error(f"not a directory: {directory}")
    if not 1 <= max_files <= 100_000:
        raise _error("max_files must be between 1 and 100000")

    sources = []
    truncated = False
    stack = [root]
    while stack:
        current = stack.pop()
        try:
            entries = sorted(current.iterdir(), key=lambda e: e.name)
        except OSError:
            continue
        for entry in entries:
            name = entry.name
            if name.startswith("."):
                if current == root and name == ".git":
                    continue  # handled via git metadata, not source walk
                if entry.is_dir():
                    continue
                continue
            try:
                is_dir = entry.is_dir()
            except OSError:
                continue
            if is_dir:
                if name in SKIP_DIRS:
                    continue
                stack.append(entry)
                continue
            if len(sources) >= max_files:
                truncated = True
                continue
            suffix = entry.suffix
            language = SOURCE_EXTS.get(suffix)
            if language is None and suffix == "":
                language = None
            try:
                size = entry.stat().st_size
            except OSError:
                continue
            if language is not None or suffix.lower() in (
                    ".a", ".so", ".dylib", ".dll", ".lib"):
                sources.append({
                    "path": entry.relative_to(root).as_posix(),
                    "language": language,
                    "bytes": size,
                })
    sources.sort(key=lambda s: s["path"])

    counts = {"c": 0, "cxx": 0, "d": 0}
    for item in sources:
        if item["language"] in counts and item["path"].rsplit(".", 1)[-1] in (
                "c", "cpp", "cxx", "cc", "C", "d"):
            counts[item["language"]] += 1

    nested_specs = []
    for spec_name in ("Rattspec", "Rattspec.m"):
        for path in root.rglob(spec_name):
            try:
                relative = path.relative_to(root).as_posix()
            except ValueError:
                continue
            if any(part.startswith(".") or part in SKIP_DIRS
                   for part in Path(relative).parts[:-1]):
                continue
            if len(path.parts) <= len(root.parts) + 1 and path.parent == root:
                continue
            nested_specs.append(relative)
    nested_specs.sort()

    ls = ls2rattpkg_module()
    try:
        libraries = sorted(ls.libraries(root).keys())
        library_error = None
    except ValueError as error:
        libraries = []
        library_error = str(error)

    git_origin = None
    if (root / ".git").exists():
        try:
            ls_git = ls2rattpkg_module()
            url = ls_git.git_output(["remote", "get-url", "origin"], cwd=root)
            git_origin = ls_git.repository_url(url)
        except Exception:
            git_origin = None

    return {
        "directory": str(root),
        "source_counts": counts,
        "source_files": [s["path"] for s in sources
                         if s["language"] is not None][:max_files],
        "binary_files": [s["path"] for s in sources
                         if s["language"] is None][:50],
        "truncated": truncated,
        "libraries": libraries,
        "library_error": library_error,
        "nested_specs": nested_specs,
        "has_root_rattspec": (root / "Rattspec").is_file(),
        "has_root_rattpkg": (root / "Rattpkg").is_file(),
        "git_origin": git_origin,
        "suggested_language": detect_language(counts),
        "suggested_target": detect_target(root, sources, detect_language(counts)),
    }


def detect_language(counts):
    """Pick c/cxx/d from source counts; cxx covers mixed C/C++."""
    if counts["cxx"]:
        return "cxx"
    if counts["c"] and counts["d"]:
        return "c" if counts["c"] >= counts["d"] else "d"
    if counts["c"]:
        return "c"
    if counts["d"]:
        return "d"
    return "empty"


def detect_target(root, sources, language):
    """Heuristic: sources defining main() build an executable."""
    if language == "empty":
        return "empty"
    pattern = MAIN_PATTERNS.get(language)
    if pattern is None:
        return "lib"
    checked = 0
    base = Path(root) if isinstance(root, (str, Path)) else None
    for item in sources:
        path = item if isinstance(item, str) else item.get("path", "")
        if not path.rsplit(".", 1)[-1] in ("c", "cpp", "cxx", "cc", "C", "d"):
            continue
        if checked >= MAX_MAIN_SCAN_FILES:
            break
        checked += 1
        try:
            full = (base / path) if base is not None else Path(path)
            if full.stat().st_size > MAX_MAIN_SCAN_BYTES:
                continue
            text = full.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if pattern.search(text):
            return "exe"
    return "lib"


def _quote(value):
    return json.dumps(value, ensure_ascii=False)


def _source_globs(source_files, language):
    exts = [e for e in SOURCE_FILE_EXTS
            if SOURCE_EXTS[e] == language
            and any(p.endswith(e) for p in source_files)]
    if not exts:
        exts = {"c": [".c"], "cxx": [".cpp"], "d": [".d"]}[language]
    rooted = any(p == "src" or p.startswith("src/") for p in source_files)
    prefix = "src/" if rooted else ""
    return [f"{prefix}**/*{ext}" for ext in sorted(exts)]


def render_rattspec(name, version, kind, language, target, members=()):
    """Render a valid root Rattspec for the detected layout."""
    ls = ls2rattpkg_module()
    project = ls.package_name(name)
    lines = [f"project(name: {_quote(project)}, version: {_quote(version)}, "
             f"kind: {_quote(kind)})"]
    if kind == "monorepo":
        lines.append("monorepo {")
        if members:
            for member in members:
                lines.append(f"  member {_quote(member)}")
        else:
            lines.append('  # member "libs/example"')
            lines.append('  # vendored "third_party/example"')
            lines.append('  # ignore "third_party/legacy"')
        lines.append("}")
    lines.append('import "fs"')
    if target == "empty" or language == "empty":
        lines.append(f"let welcome = rule(name: {_quote('welcome')}, "
                     f"output: {_quote('build/welcome.txt')})")
        lines.append(f"action(welcome) {{ fs.write({_quote('build/welcome.txt')}, "
                     f"{_quote(f'Hello from {project}!')}) }}")
        return "\n".join(lines) + "\n"
    lines.append('import "target"')
    # NOTE: keep in sync with profiles/*.in target declarations.
    globs = " + ".join(f'fs.glob({_quote(g)})'
                       for g in _source_globs(_last_scan_files, language))
    call = "executable" if target == "exe" else "library"
    lines.append(f"target.{call}(name: {_quote(project)}, language: "
                 f"{_quote(language)}, sources: {globs})")
    return "\n".join(lines) + "\n"


# Last scan's file list used to root generated globs; set by generate_*.
_last_scan_files = []


def generate_rattspec(directory, name=None, version="0.1.0", kind="auto",
                      language="auto", target="auto", output=None, force=False):
    """Write a Rattspec derived from the directory scan."""
    global _last_scan_files
    root = Path(directory).expanduser().resolve(strict=False)
    if not root.is_dir():
        raise _error(f"not a directory: {directory}")
    scan = scan_directory(root)
    _last_scan_files = scan["source_files"]
    project = name or root.name
    members = sorted({p.rsplit("/", 1)[0] for p in scan["nested_specs"]
                      if "/" in p})
    resolved_kind = ("monorepo" if (members or kind == "monorepo")
                     else "single") if kind == "auto" else kind
    if resolved_kind not in ("single", "monorepo"):
        raise _error("kind must be single, monorepo, or auto")
    resolved_language = (scan["suggested_language"] if language == "auto"
                         else language)
    if resolved_language not in ("c", "cxx", "d", "empty"):
        raise _error("language must be auto, c, cxx, d, or empty")
    if resolved_language == "empty":
        resolved_target = "empty"
    else:
        resolved_target = (scan["suggested_target"] if target == "auto"
                           else target)
        if resolved_target not in ("exe", "lib"):
            raise _error("target must be auto, exe, or lib")
    text = render_rattspec(project, version, resolved_kind,
                           resolved_language, resolved_target, members)
    out = Path(output).expanduser() if output else root / "Rattspec"
    _write_file(out, text, force)
    return {
        "path": str(out.resolve() if out.exists() else out.absolute()),
        "project": project,
        "kind": resolved_kind,
        "language": resolved_language,
        "target": resolved_target,
        "members": members,
        "scan": {k: scan[k] for k in (
            "source_counts", "libraries", "nested_specs",
            "suggested_language", "suggested_target")},
    }


def generate_rattpkg(directory, name=None, version="0.1.0", license_="NOASSERTION",
                     output=None, force=False, dotenv=None, repo=None,
                     exclude=()):
    """Write a pinned Rattpkg using ls2rattpkg discovery."""
    ls = ls2rattpkg_module()
    root = Path(directory).expanduser()
    try:
        root = root.resolve(strict=True)
    except OSError:
        raise _error(f"directory not found: {directory}")
    if not root.is_dir():
        raise _error(f"not a directory: {directory}")
    out = Path(output).expanduser() if output else root / "Rattpkg"
    if out.exists() and not force:
        raise _error(f"{out} already exists; use force to replace it")
    overrides = dict(repo or {})
    excluded = set(exclude or ())
    entries = ls.libraries(root)
    unknown = sorted(set(overrides) - set(entries))
    if unknown:
        raise _error("--repo names not found in directory: " + ", ".join(unknown))
    conflicted = sorted(set(overrides) & excluded)
    if conflicted:
        raise _error("--repo and --exclude both name: " + ", ".join(conflicted))
    entries = {k: v for k, v in entries.items() if k not in excluded}
    github = github_module()
    warning = None
    if dotenv or dotenv is None:
        try:
            github.load_credentials(dotenv)
        except ImportError:
            warning = ("python-dotenv is not installed; "
                       "continuing without .env credentials")
        except Exception as error:
            warning = f"could not load .env credentials: {error}"
    dependencies, unresolved = [], []
    for dep_name, entry in entries.items():
        try:
            url, revision = ls.discover(dep_name, entry, github,
                                        overrides.get(dep_name))
            dependencies.append((dep_name, url, revision))
        except Exception as error:
            unresolved.append(dep_name)
            print(f"{dep_name}: {error}", file=sys.stderr)
    package = ls.package_name(name or root.name)
    text = ls.render(package, version, license_, dependencies, unresolved)
    _write_file(out, text, force)
    result = {
        "path": str(out.resolve() if out.exists() else out.absolute()),
        "package": package,
        "dependencies": [{"name": n, "url": u, "rev": r}
                         for n, u, r in sorted(dependencies)],
        "unresolved": sorted(unresolved),
    }
    if warning:
        result["warning"] = warning
    return result


def generate_project(directory, name=None, version="0.1.0",
                     license_="NOASSERTION", kind="auto", language="auto",
                     target="auto", force=False, dotenv=None, repo=None,
                     exclude=(), output_spec=None, output_rattpkg=None,
                     write_rattspec=True, write_rattpkg=True):
    """Scan once, then write Rattspec and/or Rattpkg with shared identity."""
    root = Path(directory).expanduser()
    try:
        resolved = root.resolve(strict=True)
    except OSError:
        raise _error(f"directory not found: {directory}")
    project = name or resolved.name
    summary = {"directory": str(resolved), "project": project,
               "version": version}
    if write_rattspec:
        summary["rattspec"] = generate_rattspec(
            resolved, name=project, version=version, kind=kind,
            language=language, target=target, output=output_spec,
            force=force)
    if write_rattpkg:
        summary["rattpkg"] = generate_rattpkg(
            resolved, name=project, version=version, license_=license_,
            output=output_rattpkg, force=force, dotenv=dotenv, repo=repo,
            exclude=exclude)
    return summary


def _write_file(path, text, force):
    path = Path(path).expanduser()
    if path.exists() and not force:
        raise _error(f"{path} already exists; use force to replace it")
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = "w" if force or not path.exists() else "x"
    try:
        with path.open(mode, encoding="utf-8") as stream:
            stream.write(text)
    except FileExistsError:
        raise _error(f"{path} already exists; use force to replace it")


# ---------------------------------------------------------------------------
# MCP protocol (JSON-RPC 2.0 over stdio, newline-delimited, stdlib only)
# ---------------------------------------------------------------------------

TOOL_SCHEMAS = {
    "scan_directory": {
        "description": "Inventory a directory: source files, libraries, "
                       "nested Rattspec files, and suggested project settings.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "directory": {"type": "string",
                              "description": "Directory to scan."},
                "max_files": {"type": "integer", "default": 5000,
                              "description": "Cap on inventoried files."},
            },
            "required": ["directory"],
        },
    },
    "search_github": {
        "description": "Search GitHub repositories by name, optionally "
                       "filtered by language.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string"},
                "language": {"type": "string"},
                "max_results": {"type": "integer", "default": 10},
                "dotenv": {"type": "string",
                           "description": "Optional .env file for credentials."},
            },
            "required": ["name"],
        },
    },
    "generate_rattpkg": {
        "description": "Write a pinned Rattpkg manifest for a directory of "
                       "libraries (GitHub search with DuckDuckGo fallback).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "directory": {"type": "string"},
                "name": {"type": "string"},
                "version": {"type": "string", "default": "0.1.0"},
                "license": {"type": "string", "default": "NOASSERTION"},
                "output": {"type": "string",
                           "description": "Default: DIRECTORY/Rattpkg."},
                "force": {"type": "boolean", "default": False},
                "dotenv": {"type": "string"},
                "exclude": {"type": "array", "items": {"type": "string"},
                            "description": "Library names to skip, e.g. "
                                           "source dirs like \"src\"."},
                "repo": {"type": "object",
                         "description": "Explicit NAME-to-URL overrides.",
                         "additionalProperties": {"type": "string"}},
            },
            "required": ["directory"],
        },
    },
    "generate_rattspec": {
        "description": "Write a Rattspec build spec derived from the "
                       "directory's source layout.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "directory": {"type": "string"},
                "name": {"type": "string"},
                "version": {"type": "string", "default": "0.1.0"},
                "kind": {"type": "string", "default": "auto",
                         "enum": ["auto", "single", "monorepo"]},
                "language": {"type": "string", "default": "auto",
                             "enum": ["auto", "c", "cxx", "d", "empty"]},
                "target": {"type": "string", "default": "auto",
                           "enum": ["auto", "exe", "lib"]},
                "output": {"type": "string",
                           "description": "Default: DIRECTORY/Rattspec."},
                "force": {"type": "boolean", "default": False},
            },
            "required": ["directory"],
        },
    },
    "generate_project": {
        "description": "Scan a directory once and write both Rattspec and "
                       "Rattpkg with a shared project name and version.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "directory": {"type": "string"},
                "name": {"type": "string"},
                "version": {"type": "string", "default": "0.1.0"},
                "license": {"type": "string", "default": "NOASSERTION"},
                "kind": {"type": "string", "default": "auto",
                         "enum": ["auto", "single", "monorepo"]},
                "language": {"type": "string", "default": "auto",
                             "enum": ["auto", "c", "cxx", "d", "empty"]},
                "target": {"type": "string", "default": "auto",
                           "enum": ["auto", "exe", "lib"]},
                "force": {"type": "boolean", "default": False},
                "dotenv": {"type": "string"},
                "repo": {"type": "object",
                         "additionalProperties": {"type": "string"}},
                "exclude": {"type": "array", "items": {"type": "string"}},
                "output_spec": {"type": "string"},
                "output_rattpkg": {"type": "string"},
                "write_rattspec": {"type": "boolean", "default": True},
                "write_rattpkg": {"type": "boolean", "default": True},
            },
            "required": ["directory"],
        },
    },
}


def _tool_result(payload):
    return {"content": [{"type": "text",
                         "text": json.dumps(payload, indent=2)}]}


def _tool_error(message):
    return {"content": [{"type": "text", "text": message}],
            "isError": True}


def call_tool(name, arguments):
    """Dispatch one tools/call; returns the MCP result object."""
    args = dict(arguments or {})
    try:
        if name == "scan_directory":
            return _tool_result(scan_directory(
                args["directory"], args.get("max_files", 5000)))
        if name == "search_github":
            github = github_module()
            if args.get("dotenv") or "dotenv" not in args:
                try:
                    github.load_credentials(args.get("dotenv"))
                except ImportError:
                    pass
            repos = github.search_repositories(
                args["name"], args.get("language"),
                args.get("max_results", 10))
            return _tool_result([{
                "name": r.get("full_name"), "url": r.get("html_url"),
                "description": r.get("description"),
                "stars": r.get("stargazers_count"),
                "language": r.get("language"),
            } for r in repos])
        if name == "generate_rattpkg":
            return _tool_result(generate_rattpkg(
                args["directory"], name=args.get("name"),
                version=args.get("version", "0.1.0"),
                license_=args.get("license", "NOASSERTION"),
                output=args.get("output"), force=args.get("force", False),
                dotenv=args.get("dotenv"), repo=args.get("repo"),
                exclude=args.get("exclude", ())))
        if name == "generate_rattspec":
            return _tool_result(generate_rattspec(
                args["directory"], name=args.get("name"),
                version=args.get("version", "0.1.0"),
                kind=args.get("kind", "auto"),
                language=args.get("language", "auto"),
                target=args.get("target", "auto"),
                output=args.get("output"), force=args.get("force", False)))
        if name == "generate_project":
            return _tool_result(generate_project(
                args["directory"], name=args.get("name"),
                version=args.get("version", "0.1.0"),
                license_=args.get("license", "NOASSERTION"),
                kind=args.get("kind", "auto"),
                language=args.get("language", "auto"),
                target=args.get("target", "auto"),
                force=args.get("force", False), dotenv=args.get("dotenv"),
                repo=args.get("repo"), exclude=args.get("exclude", ()),
                output_spec=args.get("output_spec"),
                output_rattpkg=args.get("output_rattpkg"),
                write_rattspec=args.get("write_rattspec", True),
                write_rattpkg=args.get("write_rattpkg", True)))
    except KeyError as error:
        return _tool_error(f"missing required argument: {error}")
    except (ValueError, RuntimeError, OSError) as error:
        return _tool_error(str(error))
    return _tool_error(f"unknown tool: {name}")


def handle_request(request):
    """Handle one JSON-RPC request; returns a response or None."""
    if not isinstance(request, dict) or request.get("jsonrpc") != "2.0":
        return {"jsonrpc": "2.0", "id": request.get("id", None)
                if isinstance(request, dict) else None,
                "error": {"code": -32600, "message": "invalid request"}}
    method = request.get("method")
    request_id = request.get("id")
    params = request.get("params") or {}

    def respond(result):
        return {"jsonrpc": "2.0", "id": request_id, "result": result}

    def fail(code, message):
        return {"jsonrpc": "2.0", "id": request_id,
                "error": {"code": code, "message": message}}

    is_notification = request_id is None
    if method == "initialize":
        offered = params.get("protocolVersion")
        version = (offered if offered in PROTOCOL_VERSIONS
                   else DEFAULT_PROTOCOL_VERSION)
        return respond({
            "protocolVersion": version,
            "capabilities": {"tools": {}, "resources": {}, "prompts": {}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
        })
    if method in ("notifications/initialized", "notifications/cancelled"):
        return None
    if is_notification:
        return None
    if method == "ping":
        return respond({})
    if method == "tools/list":
        return respond({"tools": [
            {"name": name, **schema} for name, schema in TOOL_SCHEMAS.items()]})
    if method == "tools/call":
        return respond(call_tool(params.get("name"),
                                 params.get("arguments") or {}))
    if method == "resources/list":
        return respond({"resources": []})
    if method == "prompts/list":
        return respond({"prompts": []})
    return fail(-32601, f"method not found: {method}")


def serve():
    """Run the MCP server: one JSON message per line on stdio."""
    for line in sys.stdin:
        if not line.strip():
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError as error:
            sys.stdout.write(json.dumps({
                "jsonrpc": "2.0", "id": None,
                "error": {"code": -32700,
                          "message": f"parse error: {error}"}}) + "\n")
            sys.stdout.flush()
            continue
        try:
            response = handle_request(request)
        except Exception as error:  # never break the session on one request
            response = {"jsonrpc": "2.0", "id": request.get("id"),
                        "error": {"code": -32603, "message": str(error)}}
            print(f"request failed: {error}", file=sys.stderr)
        if response is not None:
            sys.stdout.write(json.dumps(response) + "\n")
            sys.stdout.flush()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("directory", nargs="?", type=Path,
                        help="One-shot mode: generate files for DIRECTORY. "
                             "Omit to serve MCP on stdio.")
    parser.add_argument("--serve", action="store_true",
                        help="Serve MCP on stdio even if a directory is given.")
    parser.add_argument("--name", help="Project/package name.")
    parser.add_argument("--version", default="0.1.0")
    parser.add_argument("--license", default="NOASSERTION")
    parser.add_argument("--kind", default="auto",
                        choices=["auto", "single", "monorepo"])
    parser.add_argument("--language", default="auto",
                        choices=["auto", "c", "cxx", "d", "empty"])
    parser.add_argument("--target", default="auto",
                        choices=["auto", "exe", "lib"])
    parser.add_argument("--dotenv", help="Path to GitHub credentials .env")
    parser.add_argument("--repo", action="append", default=[],
                        metavar="NAME=URL")
    parser.add_argument("--exclude", action="append", default=[],
                        help="Skip a library name during Rattpkg discovery "
                             "(repeatable, e.g. --exclude src).")
    parser.add_argument("--output-spec", type=Path)
    parser.add_argument("--output-pkg", type=Path)
    parser.add_argument("--no-rattspec", action="store_true")
    parser.add_argument("--no-rattpkg", action="store_true")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args(argv)
    if args.directory is None or args.serve:
        if args.directory is not None and args.serve:
            print("ignoring directory argument; serving MCP on stdio",
                  file=sys.stderr)
        serve()
        return 0
    try:
        overrides = {}
        for override in args.repo:
            item, separator, url = override.partition("=")
            if not separator or not item or not url:
                raise _error("--repo must be NAME=URL")
            overrides[item] = url
        summary = generate_project(
            args.directory, name=args.name, version=args.version,
            license_=args.license, kind=args.kind, language=args.language,
            target=args.target, force=args.force, dotenv=args.dotenv,
            repo=overrides, exclude=args.exclude, output_spec=args.output_spec,
            output_rattpkg=args.output_pkg,
            write_rattspec=not args.no_rattspec,
            write_rattpkg=not args.no_rattpkg)
        print(json.dumps(summary, indent=2))
        unresolved = summary.get("rattpkg", {}).get("unresolved", [])
        return 1 if unresolved else 0
    except (ValueError, RuntimeError, OSError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    sys.exit(main())
