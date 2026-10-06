#!/usr/bin/env python3
"""GitHub repository search, usable as a CLI or an imported module."""

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request


def load_credentials(dotenv_path=None):
    """Environment wins over .env; credentials are never added to URLs."""
    from dotenv import find_dotenv, load_dotenv

    load_dotenv(dotenv_path or find_dotenv(usecwd=True), override=False)


def search_repositories(name, language=None, max_results=10, token=None):
    if not 1 <= max_results <= 100:
        raise ValueError("max_results must be between 1 and 100")
    query = name + (f" language:{language}" if language else "")
    params = urllib.parse.urlencode(
        {"q": query, "sort": "stars", "order": "desc", "per_page": max_results}
    )
    headers = {
        "User-Agent": "rattpack-github-grep",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    token = (token or os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
             or os.environ.get("GITHUB_API_KEY"))
    if token:
        headers["Authorization"] = "Bearer " + token
    request = urllib.request.Request(
        "https://api.github.com/search/repositories?" + params, headers=headers
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            data = json.load(response)
            if not isinstance(data, dict) or not isinstance(data.get("items"), list):
                raise RuntimeError("GitHub search returned an invalid result")
            return data["items"]
    except urllib.error.HTTPError as error:
        detail = ""
        if error.code in (403, 429):
            detail = "; rate limit or access denied (check GITHUB_TOKEN)"
        raise RuntimeError(f"GitHub search failed: HTTP {error.code}{detail}") from error
    except urllib.error.URLError as error:
        raise RuntimeError(f"GitHub search failed: {error.reason}") from error
    except (TimeoutError, json.JSONDecodeError) as error:
        raise RuntimeError("GitHub search timed out or returned invalid JSON") from error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", required=True)
    parser.add_argument("--lang", "--language", dest="language")
    parser.add_argument("--max", type=int, default=10, dest="max_results")
    parser.add_argument("--dotenv", help="Path to .env (default: discover from CWD)")
    parser.add_argument("--json", action="store_true", help="Print the API result list")
    args = parser.parse_args()
    try:
        load_credentials(args.dotenv)
        repos = search_repositories(args.name, args.language, args.max_results)
    except (ImportError, ValueError, RuntimeError) as error:
        parser.exit(1, f"{error}\n")
    if args.json:
        print(json.dumps(repos, indent=2))
    else:
        for repo in repos:
            print(f"{repo['full_name']}\t{repo['html_url']}\t"
                  f"{repo.get('description') or ''}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
