#!/usr/bin/env python3
"""Exercise the real language-server protocol and installed editor runtimes."""
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SERVER = ROOT / "build" / ("ratt-language-server.exe" if os.name == "nt" else "ratt-language-server")


def frame(message):
    body = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode()
    return b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body


def request(identifier, method, params=None):
    return {"jsonrpc": "2.0", "id": identifier, "method": method, "params": params or {}}


def notify(method, params=None):
    return {"jsonrpc": "2.0", "method": method, "params": params or {}}


def open_file(path, text, language="rattscript", version=1):
    return notify("textDocument/didOpen", {"textDocument": {
        "uri": path.as_uri(), "text": text, "languageId": language, "version": version}})


def at(path, line=0, character=0):
    return {"textDocument": {"uri": path.as_uri()}, "position": {"line": line, "character": character}}


def exchange(messages, extra=b"", expected=0):
    result = subprocess.run([str(SERVER), "--stdio"], input=extra + b"".join(map(frame, messages)),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    assert result.returncode == expected, result.stderr.decode()
    output = result.stdout
    decoded = []
    while output:
        header, separator, tail = output.partition(b"\r\n\r\n")
        assert separator, output
        match = re.fullmatch(rb"Content-Length: ([0-9]+)", header)
        assert match, header
        length = int(match[1])
        decoded.append(json.loads(tail[:length]))
        output = tail[length:]
    responses = {item["id"]: item for item in decoded if "id" in item}
    return decoded, responses


def shutdown():
    return [request("shutdown", "shutdown"), notify("exit")]


def diagnostics(messages, path):
    return [item["params"] for item in messages
            if item.get("method") == "textDocument/publishDiagnostics"
            and item["params"]["uri"] == path.as_uri()]


def test_protocol(work):
    script = work / "a space 雪.ratt"
    text = 'let greeting = "😀"; let count: int = "bad"\n'
    messages = [request(1, "initialize"), open_file(script, text),
                notify("textDocument/didChange", {"textDocument": {"uri": script.as_uri(), "version": 2},
                       "contentChanges": [{"range": {"start": {"line": 0, "character": 38},
                                                    "end": {"line": 0, "character": 43}}, "text": "7"}]}),
                request(2, "textDocument/hover", at(script, 0, 26))] + shutdown()
    decoded, responses = exchange(messages)
    assert responses[1]["result"]["capabilities"]["textDocumentSync"]["change"] == 2
    reports = diagnostics(decoded, script)
    assert reports[0]["diagnostics"][0]["code"] == "E_TYPE"
    assert reports[0]["diagnostics"][0]["range"]["start"] == {"line": 0, "character": 21}
    assert reports[1]["diagnostics"] == [] and reports[1]["version"] == 2
    assert "let count: int" in responses[2]["result"]["contents"]["value"]
    assert not script.exists(), "editor overlays must never overwrite files"

    completion = work / "completion.ratt"
    source = 'import "json" as codec\ncodec.\n'
    decoded, responses = exchange([request(1, "initialize"), open_file(completion, source),
                                   request(2, "textDocument/completion", at(completion, 1, 6))] + shutdown())
    items = responses[2]["result"]
    assert {item["label"] for item in items} >= {"parse", "stringify", "get"}
    assert all(item["textEdit"]["range"]["start"] == {"line": 1, "character": 6} for item in items)
    source = 'import "json" as codec\ncodec.stringify({x: 1})\n'
    _, responses = exchange([request(1, "initialize"), open_file(completion, source),
                            request(2, "textDocument/hover", at(completion, 1, 8)),
                            request(3, "textDocument/documentSymbol", at(completion))] + shutdown())
    assert "json.stringify" in responses[2]["result"]["contents"]["value"]
    assert any(symbol["name"] == "codec" for symbol in responses[3]["result"])
    _, responses = exchange([request(1, "initialize"), open_file(completion, 'let local_name = 1\nprint(local_name'),
                            request(2, "textDocument/completion", at(completion, 1, 9))] + shutdown())
    local = next(item for item in responses[2]["result"] if item["label"] == "local_name")
    assert local["textEdit"]["range"] == {"start": {"line": 1, "character": 6}, "end": {"line": 1, "character": 16}}

    _, responses = exchange([request(1, "textDocument/hover"), request(2, "initialize"),
                            request(3, "not/a/method"), request(4, "textDocument/hover", {"textDocument": {}})]
                           + shutdown(), extra=b"Content-Length: 1\r\n\r\n{")
    assert responses[None]["error"]["code"] == -32700
    assert responses[1]["error"]["code"] == -32002
    assert responses[3]["error"]["code"] == -32601
    assert responses[4]["error"]["code"] == -32602
    exchange([notify("exit")], expected=1)
    exchange([], extra=b"Content-Length: 100\r\n\r\n{}", expected=1)
    print("PASS LSP framing, lifecycle, UTF-16 edits, diagnostics, completion, hover and symbols")


def test_imports(work):
    helper = work / "helper.ratt"
    side_effect = work / "must-not-exist"
    helper.write_text('import "fs"\nfs.write("' + str(side_effect).replace("\\", "\\\\")
                      + '", "bad")\nfn answer() -> int { return 42 }\n')
    script = work / "main.ratt"
    text = 'import "./helper.ratt" as tools\nprint(tools.answer())\n'
    decoded, responses = exchange([request(1, "initialize"), open_file(script, text),
                                   request(2, "textDocument/definition", at(script, 1, 13)),
                                   open_file(helper, 'fn answer() -> int { return "bad" }\n', version=2),
                                   request(3, "textDocument/definition", at(script, 1, 13)),
                                   notify("textDocument/didClose", {"textDocument": {"uri": helper.as_uri()}})] + shutdown())
    assert responses[2]["result"][0]["uri"] == helper.as_uri()
    assert responses[2]["result"][0]["range"]["start"]["line"] == 2
    assert responses[3]["result"][0]["range"]["start"]["line"] == 0
    reports = diagnostics(decoded, script)
    assert reports[0]["diagnostics"] == []
    assert reports[1]["diagnostics"][0]["code"] == "E_TYPE"
    assert reports[1]["diagnostics"][0]["relatedInformation"][0]["location"]["uri"] == helper.as_uri()
    assert reports[-1]["diagnostics"] == []
    assert not side_effect.exists()
    helper.write_text('import "./main.ratt"\n')
    script.write_text(text)
    decoded, _ = exchange([request(1, "initialize"), open_file(script, text)] + shutdown())
    assert "cyclic" in diagnostics(decoded, script)[0]["diagnostics"][0]["message"]
    template = work / "example.ratt.in"
    decoded, _ = exchange([request(1, "initialize"), open_file(template,
                         '@if true\nlet x = @{proc.run(["false"])}\n@end\n')]
                         + shutdown())
    assert diagnostics(decoded, template)[0]["diagnostics"] == []
    print("PASS static imports, unsaved imported overlays, definitions, cycles and templates")


def test_configs():
    for path in (ROOT / "addons/lsp").glob("*.json"):
        config = json.loads(path.read_text())
        assert config["command"] == ["ratt-language-server", "--stdio"]
        assert "Rattspec" in config["rootMarkers"]
    for path in (ROOT / "addons/sublime").glob("*.sublime-settings"):
        config = json.loads(path.read_text())
        if path.name.startswith("LSP-"):
            assert "selector" in config and "clients" not in config
    with (ROOT / "addons/sublime/Rattpack.tmPreferences").open("rb") as file:
        plistlib.load(file)
    # Keep the standalone Vim and Neovim language runtimes in lockstep.
    vim = ROOT / "addons/vim/ratt-languages"
    neovim = ROOT / "addons/neovim/ratt-languages"
    for path in vim.rglob("*.vim"):
        assert path.read_bytes() == (neovim / path.relative_to(vim)).read_bytes(), path
    print("PASS generic LSP/Sublime settings, preferences and matching editor runtimes")


def test_vim(work, editor):
    runtime = ROOT / "addons" / ("neovim" if editor == "nvim" else "vim") / "ratt-languages"
    test = work / (editor + "-test.vim")
    error_log = work / (editor + "-errors.txt")
    bad = work / "lint space.ratt"
    bad.write_text('let count: int = "bad"\n')
    test.write_text("set nocompatible\nset rtp^=" + str(runtime) + "\n"
                    "let g:ratt_lsp_enabled = 0\nfiletype plugin indent on\nsyntax on\n"
                    "let g:ratt_lint_program = '" + str(ROOT / "build/rattsc") + "'\n"
                    "for [filename, expected] in [['test.ratt', 'rattscript'], ['test.ratt.in', 'rattscript'], "
                    "['Rattspec', 'rattspec'], ['Rattspec.m', 'rattspec'], ['Rattspec.m.in', 'rattspec'], "
                    "['Rattpkg', 'rattpkg'], ['Rattpkg.in', 'rattpkg']]\n"
                    "  execute 'edit ' . fnameescape('" + str(work) + "/' . filename)\n"
                    "  call assert_equal(expected, &filetype)\n"
                    "  call assert_equal('# %s', &commentstring)\n"
                    "  call assert_equal(2, &shiftwidth)\n"
                    "  call assert_equal(expected, b:current_syntax)\nendfor\n"
                    "enew!\nsetfiletype rattscript\n"
                    "call setline(1, ['fn test() {', 'if true {', 'print(\"}\") // {', '}', 'print(1)', '}'])\n"
                    "normal! gg=G\n"
                    "call assert_equal([0, 2, 4, 2, 2, 0], map(range(1, 6), 'indent(v:val)'))\n"
                    "call assert_equal('rattscriptComment', synIDattr(synID(3, 16, 1), 'name'))\n"
                    "call setline(1, ['let name = \"escaped\\\" text\"', \"let label = 'single'\", 'let x = 1.5e-2'])\n"
                    "syntax sync fromstart\n"
                    "call assert_equal('rattscriptString', synIDattr(synID(1, 23, 1), 'name'))\n"
                    "call assert_equal('rattscriptString', synIDattr(synID(2, 15, 1), 'name'))\n"
                    "call assert_equal('rattscriptNumber', synIDattr(synID(3, 13, 1), 'name'))\n"
                    "call assert_true(index(ratt#Complete(0, 'pri'), 'print') >= 0)\n"
                    "execute 'edit! ' . fnameescape('" + str(bad) + "')\nRattLint\n"
                    "call assert_equal(1, len(getloclist(0)))\n"
                    "call assert_equal(1, getloclist(0)[0].lnum)\n"
                    "call assert_match('E_TYPE', getloclist(0)[0].text)\n"
                    "if !empty(v:errors)\ncall writefile(v:errors, '" + str(error_log) + "')\ncquit\nendif\nqa!\n")
    command = [editor, "--headless", "-u", "NONE", "-S", str(test)] if editor == "nvim" else [editor, "-Nu", "NONE", "-n", "-es", "-S", str(test)]
    environment = os.environ.copy()
    environment.pop("VIM", None)
    environment.pop("VIMRUNTIME", None)
    result = subprocess.run(command, capture_output=True, text=True, env=environment, timeout=30)
    assert result.returncode == 0, (error_log.read_text() if error_log.exists() else result.stdout + result.stderr)
    print("PASS", editor, "file detection, syntax, indentation, completion and lint location list")


def test_neovim_lsp(work):
    script = work / "neovim-lsp.lua"
    file = work / "live.ratt"
    file.write_text('let count: int = "bad"\n')
    runtime = ROOT / "addons/neovim/ratt-languages"
    script.write_text("vim.opt.rtp:prepend(" + json.dumps(str(runtime)) + ")\n"
                      "vim.cmd('filetype plugin indent on')\n"
                      "require('ratt').setup({cmd = {" + json.dumps(str(SERVER)) + ", '--stdio'}})\n"
                      "vim.cmd('runtime plugin/ratt.lua')\n"
                      "vim.cmd('edit ' .. vim.fn.fnameescape(" + json.dumps(str(file)) + "))\n"
                      "assert(vim.wait(10000, function() return #vim.diagnostic.get(0) > 0 end, 20), 'no LSP diagnostics')\n"
                      "assert(vim.diagnostic.get(0)[1].code == 'E_TYPE')\n"
                      "vim.api.nvim_buf_set_lines(0, 0, -1, false, {'let count: int = 7'})\n"
                      "assert(vim.wait(10000, function() return #vim.diagnostic.get(0) == 0 end, 20), 'stale diagnostics')\n"
                      "vim.cmd('qa!')\n")
    environment = os.environ.copy()
    environment.pop("VIM", None)
    environment.pop("VIMRUNTIME", None)
    result = subprocess.run(["nvim", "--headless", "-u", "NONE", "-c", "lua dofile(" + json.dumps(str(script)) + ")"],
                            capture_output=True, text=True, env=environment, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
    print("PASS Neovim live LSP attachment and unsaved-change diagnostics")


def main():
    test_configs()
    temporary = "/tmp/opencode" if Path("/tmp/opencode").is_dir() else None
    with tempfile.TemporaryDirectory(prefix="rattpack-addons-", dir=temporary) as directory:
        work = Path(directory)
        test_protocol(work)
        test_imports(work)
        for editor in ("vim", "nvim"):
            if shutil.which(editor):
                test_vim(work, editor)
            else:
                print("SKIP", editor, "is not installed")
        if shutil.which("nvim"):
            test_neovim_lsp(work)


if __name__ == "__main__":
    main()
