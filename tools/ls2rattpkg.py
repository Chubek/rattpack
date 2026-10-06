#!/usr/bin/env python3
"""Generate a pinned Rattpkg from library directories or compiled libraries."""

import argparse
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlparse, urlunparse


def github_module():
    spec = importlib.util.spec_from_file_location(
        "github_grep", Path(__file__).with_name("github-grep.py")
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def package_name(text):
    name = re.sub(r"[^A-Za-z0-9_.-]+", "-", text).strip(".-")
    if not name:
        raise ValueError(f"cannot derive a package name from {text!r}")
    return name


def normalized(text):
    text = re.sub(r"[^a-z0-9]", "", text.lower())
    return text[3:] if text.startswith("lib") else text


def libraries(directory):
    """Immediate subdirectories and .a/.so/.dylib/.dll/.lib files, deduplicated."""
    found = {}
    original_names = {}
    for entry in sorted(directory.iterdir()):
        if entry.name.startswith("."):
            continue
        if entry.is_dir():
            original = entry.name
        elif entry.is_file():
            match = re.fullmatch(r"(.+?)(?:\.so(?:\.\d+)*|\.a|\.dylib|\.dll|\.lib)",
                                 entry.name, re.IGNORECASE)
            if not match:
                continue
            original = match[1]
        else:
            continue
        name = package_name(original)
        if name in original_names and original_names[name] != original:
            raise ValueError(f"directory entries collide on package name {name!r}")
        original_names[name] = original
        if name not in found or entry.is_dir():
            found[name] = entry
    return found


def repository_url(url):
    """Canonicalize repository links, including GitHub/GitLab tree links."""
    if url.startswith("git@"):
        match = re.fullmatch(r"git@([^:]+):(.+)", url)
        if match:
            url = f"https://{match[1]}/{match[2]}"
    parsed = urlparse(url)
    if parsed.scheme not in ("https", "http", "git", "ssh") or not parsed.hostname:
        raise ValueError("not a remote Git URL")
    if parsed.password or (parsed.username and parsed.scheme != "ssh"):
        raise ValueError("repository URL must not contain credentials")
    parts = parsed.path.strip("/").split("/")
    if parsed.hostname.lower() in ("github.com", "bitbucket.org", "codeberg.org"):
        if len(parts) < 2:
            raise ValueError("not a repository link")
        parts = parts[:2]
    elif "-" in parts:
        parts = parts[:parts.index("-")]
    path = "/" + "/".join(parts).removesuffix(".git")
    return urlunparse((parsed.scheme, parsed.netloc, path, "", "", ""))


def git_output(arguments, cwd=None):
    import os

    result = subprocess.run(
        ["git", *arguments], cwd=cwd, text=True, capture_output=True, timeout=30,
        env={**os.environ, "GIT_TERMINAL_PROMPT": "0"}, check=False,
    )
    if result.returncode:
        raise RuntimeError("Git lookup failed")
    return result.stdout.strip()


def remote_revision(url):
    output = git_output(["ls-remote", "--", url, "HEAD"])
    for line in output.splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[1] == "HEAD" and re.fullmatch(
                r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", fields[0]):
            return fields[0].lower()
    raise RuntimeError("repository has no advertised HEAD revision")


def web_repositories(name):
    from ddgs import DDGS

    results = DDGS().text(f'"{name}" library source code git repository',
                          max_results=10, backend="duckduckgo")
    seen = set()
    for result in results:
        try:
            url = repository_url(result.get("href") or result.get("url") or "")
        except ValueError:
            continue
        # Do not mistake a documentation or download page for a repository.
        if normalized(urlparse(url).path.rsplit("/", 1)[-1]) != normalized(name):
            continue
        if url not in seen:
            seen.add(url)
            yield url


def discover(name, entry, github, override=None):
    if override:
        url = repository_url(override)
        return url, remote_revision(url)
    # A directory's own Git metadata is stronger evidence than a name search.
    # Check .git explicitly to avoid inheriting the containing project's origin.
    if entry.is_dir() and (entry / ".git").exists():
        try:
            url = repository_url(git_output(["remote", "get-url", "origin"], cwd=entry))
            return url, remote_revision(url)
        except (ValueError, RuntimeError, subprocess.TimeoutExpired):
            pass
    try:
        repos = github.search_repositories(name + " in:name", max_results=20)
    except RuntimeError as error:
        print(f"{name}: {error}; trying web search", file=sys.stderr)
        repos = []
    for repo in repos:
        if repo.get("fork") or repo.get("archived"):
            continue
        if normalized(repo.get("name", "")) != normalized(name):
            continue
        try:
            url = repository_url(repo.get("clone_url") or repo["html_url"])
            return url, remote_revision(url)
        except (ValueError, RuntimeError, subprocess.TimeoutExpired):
            continue
    for url in web_repositories(name):
        try:
            return url, remote_revision(url)
        except (ValueError, RuntimeError, subprocess.TimeoutExpired):
            continue
    raise RuntimeError("no matching Git repository found; use --repo NAME=URL")


def render(name, version, license_, dependencies, unresolved):
    quote = lambda value: json.dumps(value, ensure_ascii=False)
    lines = [f"package(name: {quote(name)}, version: {quote(version)}, "
             f"license: {quote(license_)})", "deps {"]
    for dependency, url, revision in sorted(dependencies):
        lines.append(f"  dep {quote(dependency)} from: git({quote(url)}), rev: {quote(revision)}")
    lines.append("}")
    for dependency in sorted(unresolved):
        lines.append(f"# Unresolved library: {dependency}")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--output", "-o", type=Path, help="Default: DIRECTORY/Rattpkg")
    parser.add_argument("--name", help="Package name (default: directory name)")
    parser.add_argument("--version", default="0.1.0")
    parser.add_argument("--license", default="NOASSERTION")
    parser.add_argument("--dotenv", help="Path to GitHub credentials .env")
    parser.add_argument("--repo", action="append", default=[], metavar="NAME=URL")
    parser.add_argument("--force", action="store_true", help="Replace an existing output")
    args = parser.parse_args()
    try:
        directory = args.directory.resolve(strict=True)
        if not directory.is_dir():
            raise ValueError("directory must be a directory")
        output = args.output or directory / "Rattpkg"
        if output.exists() and not args.force:
            raise ValueError(f"{output} already exists; use --force to replace it")
        overrides = {}
        for override in args.repo:
            name, separator, url = override.partition("=")
            if not separator or not name or not url:
                raise ValueError("--repo must be NAME=URL")
            overrides[name] = url
        entries = libraries(directory)
        unknown = overrides.keys() - entries.keys()
        if unknown:
            raise ValueError("--repo names not found in directory: " + ", ".join(sorted(unknown)))
        github = github_module()
        github.load_credentials(args.dotenv)
        dependencies, unresolved = [], []
        for name, entry in entries.items():
            try:
                url, revision = discover(name, entry, github, overrides.get(name))
                dependencies.append((name, url, revision))
                print(f"{name}: {url} @ {revision}", file=sys.stderr)
            except Exception as error:
                unresolved.append(name)
                print(f"{name}: {error}", file=sys.stderr)
        text = render(package_name(args.name or directory.name), args.version,
                      args.license, dependencies, unresolved)
        with output.open("w" if args.force else "x", encoding="utf-8") as stream:
            stream.write(text)
        print(f"Wrote {output}: {len(dependencies)} dependencies, "
              f"{len(unresolved)} unresolved", file=sys.stderr)
        return 1 if unresolved else 0
    except (OSError, ValueError, ImportError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    sys.exit(main())
