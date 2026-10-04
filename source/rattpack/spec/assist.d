module rattpack.spec.assist;

import rattpack.diagnostic : Diagnostic, Location, fail;
import rattpack.rt.sys : atomicWrite;
import rattpack.script.ast;
import rattpack.config.environment : Configuration;
import rattpack.pkg.manifest : parseManifest;
import rattpack.script.lint : lint;
import rattpack.script.parser : Parser;
import rattpack.script.value : Value;
import rattpack.serialization : canonical, jsonObject;
import std.algorithm : canFind, sort;
import std.file : exists, isDir, isFile, isSymlink, readText, remove, dirEntries, SpanMode;
import std.json : JSONValue, JSONType, parseJSON;
import std.path : absolutePath, baseName, buildPath, relativePath;
import std.string : endsWith, lastIndexOf, replace, startsWith, strip;

private static immutable filenames = ["Rattspec", "Rattpkg"];

struct AssistFile
{
    bool present;
    string contents;
}

/// The input files captured before a potentially slow model request.
struct AssistProject
{
    string root;
    AssistFile[string] files;
    string[] inventory;

    string prompt(string request) @safe
    {
        auto context = jsonObject();
        context["request"] = JSONValue(request);
        context["directory_name"] = JSONValue(baseName(root));
        context["paths"] = JSONValue(inventory);
        auto existing = jsonObject();
        foreach (name; filenames)
            existing[name] = files[name].present ? JSONValue(files[name].contents) : JSONValue(null);
        context["existing_files"] = existing;
        return instructions ~ "\nProject context (JSON):\n" ~ canonical(context);
    }
}

struct AssistProposal
{
    string[string] files;
    string summary;

    JSONValue toJSON() @safe
    {
        auto result = jsonObject();
        auto output = jsonObject();
        foreach (name, contents; files)
            output[name] = JSONValue(contents);
        result["files"] = output;
        result["summary"] = JSONValue(summary);
        return result;
    }
}

/// isSymlink throws for a missing path; treat "not there" as a plain absence.
bool assistSymlink(string path) @safe
{
    return exists(path) && isSymlink(path);
}

/// Diagnostics carry their own "file:line:col" prefix; strip it before rewrapping.
string stripLocation(string message) @safe
{
    auto start = message.lastIndexOf(": ");
    if (start == size_t.max)
        return message;
    foreach (c; message[start + 2 .. $])
        if (c == ' ' || c == ':' || c == '\t')
            return message[start + 2 .. $];
    return message;
}

/// Read only the two editable files and a bounded, sorted source-path inventory.
AssistProject readAssistProject(string directory)
{
    AssistProject project;
    project.root = absolutePath(directory);
    if (!exists(project.root) || !isDir(project.root))
        fail("E_CLI", "project directory does not exist: " ~ project.root);
    foreach (name; filenames)
    {
        if (assistSymlink(buildPath(project.root, name ~ ".in")))
            fail("E_ASSIST", "assist requires a plain " ~ name ~ "; a template already exists");
        project.files[name] = readAssistFile(buildPath(project.root, name));
    }
    void collect(string directory)
    {
        string[] entries;
        foreach (entry; dirEntries(directory, SpanMode.shallow))
            if (!entry.isSymlink && !baseName(entry.name).startsWith(".")
                    && !["build", "node_modules", "third_party"].canFind(baseName(entry.name)))
                entries ~= entry.name;
        entries.sort;
        foreach (path; entries)
        {
            if (project.inventory.length == 256)
                break;
            if (isDir(path))
                collect(path);
            else if (isFile(path))
                project.inventory ~= relativePath(path, project.root).replace("\\", "/");
        }
    }

    collect(project.root);
    return project;
}

private AssistFile readAssistFile(string path)
{
    if (assistSymlink(path) || (exists(path) && !isFile(path)))
        fail("E_ASSIST", "assist needs a regular file: " ~ path);
    return exists(path) ? AssistFile(true, readText(path)) : AssistFile.init;
}

/// Decode complete replacement files. Parsing and linting never evaluate them.
AssistProposal decodeAssistProposal(string text, AssistProject project)
{
    text = text.strip;
    if (text.startsWith("```json\n") || text.startsWith("```\n"))
    {
        auto prefix = text.startsWith("```json\n") ? 8 : 4;
        if (!text.endsWith("\n```"))
            fail("E_ASSIST", "OpenCode returned an unterminated JSON fence");
        text = text[prefix .. $ - 4].strip;
    }
    JSONValue response;
    try
    {
        response = parseJSON(text);
    }
    catch (Exception)
    {
        fail("E_ASSIST", "OpenCode must return a JSON object containing files and a summary");
    }
    if (response.type != JSONType.object)
        fail("E_ASSIST", "OpenCode response is not an object");
    foreach (key; response.objectNoRef.keys)
        if (!["files", "summary"].canFind(key))
            fail("E_ASSIST", "unknown OpenCode response field: " ~ key);
    auto output = "files" in response.objectNoRef;
    if (output is null || output.type != JSONType.object)
        fail("E_ASSIST", "OpenCode response needs a files object");
    AssistProposal proposal;
    if (auto summary = "summary" in response.objectNoRef)
    {
        if (summary.type != JSONType.string)
            fail("E_ASSIST", "OpenCode summary must be a string");
        proposal.summary = summary.str;
    }
    foreach (name, contents; output.objectNoRef)
    {
        if (!filenames.canFind(name))
            fail("E_ASSIST", "OpenCode proposed an unsupported file: " ~ name);
        if (contents.type != JSONType.string || !contents.str.strip.length)
            fail("E_ASSIST", "OpenCode file contents must be a nonempty string: " ~ name);
        validateAssistSource(name, contents.str);
        proposal.files[name] = contents.str;
        if (name == "Rattpkg")
        {
            // Run the real manifest reader over the proposal so dependency
            // sources, pins, checksums and duplicate names are host-validated.
            try
            {
                // The label is only used for diagnostics; nothing is written.
                parseManifest(contents.str, buildPath(project.root, "Rattpkg"),
                        new Configuration(cast(Value[string]) null));
            }
            catch (Diagnostic diagnostic)
            {
                fail("E_ASSIST", "proposed Rattpkg is invalid: " ~ diagnostic.code
                        ~ ": " ~ stripLocation(diagnostic.msg), diagnostic.location);
            }
        }
    }
    foreach (name; filenames)
        if (!project.files.get(name, AssistFile.init).present && !(name in proposal.files))
            fail("E_ASSIST", "OpenCode did not create the missing " ~ name);
    return proposal;
}

private void validateAssistSource(string name, string source) @safe
{
    auto ast = new Parser(source, name).parse;
    lint(ast);
    auto identity = name == "Rattspec" ? "project" : "package";
    size_t identities;
    bool target;
    foreach (statement; ast.statements)
    {
        auto expression = statement.expression;
        if (statement.kind != StmtKind.expression || expression.kind != ExprKind.call
                || expression.left.kind != ExprKind.name || expression.left.text != identity)
            continue;
        identities++;
        // Identity metadata is part of every cache, lockfile and target name.
        // Require literal strings so a typo cannot produce a valid-looking file.
        foreach (entry; expression.entries)
            if (entry.kind != ExprKind.literal || (entry.literal.kind != Value.Kind.text
                    && entry.literal.kind != Value.Kind.path))
                fail("E_ASSIST", identity ~ "() metadata must be quoted string literals",
                        entry.location);
        foreach (i, key; expression.names)
        {
            auto argument = expression.entries[i];
            if (key == "kind" && !["single", "multi-module",
                    "monorepo"].canFind(argument.literal.text))
                fail("E_ASSIST", "invalid project kind: " ~ argument.literal.text,
                        argument.location);
        }
    }
    if (name != "Rattspec")
    {
        if (identities != 1)
            fail("E_ASSIST", name ~ " needs exactly one top-level " ~ identity ~ "() declaration");
        return;
    }
    void visitExpression(Expr expression) @safe
    {
        if (expression is null)
            return;
        if (expression.kind == ExprKind.call)
        {
            auto function_ = expression.left;
            if (function_.kind == ExprKind.name && ["target", "rule"].canFind(function_.text))
                target = true;
            if (function_.kind == ExprKind.member && [
                    "executable", "library", "rule"
                ].canFind(function_.text))
                target = true;
            if (function_.kind == ExprKind.name && function_.text == "module" && name == "Rattspec")
                fail("E_IDENTITY_MISMATCH", "module() requires Rattspec.m", expression.location);
        }
        visitExpression(expression.left);
        visitExpression(expression.right);
        foreach (entry; expression.entries)
            visitExpression(entry);
    }

    void visit(Stmt statement) @safe
    {
        if (statement is null)
            return;
        if (statement.kind == StmtKind.import_ && [
            "Rattspec", "Rattspec.m", "Rattspec.in", "Rattspec.m.in"
        ].canFind(baseName(statement.name)))
            fail("E_IMPORT", "spec discovery is automatic; do not import specs",
                    statement.location);
        visitExpression(statement.expression);
        foreach (child; statement.statements)
            visit(child);
        visit(statement.body);
        visit(statement.otherwise);
    }

    visit(ast);
    // Checked after the walk so a subordinate module() reports the identity error.
    if (identities != 1)
        fail("E_ASSIST", name ~ " needs exactly one top-level " ~ identity ~ "() declaration");
    if (!target)
        fail("E_ASSIST", "Rattspec needs at least one target declaration");
}

/// Check for edits made while generation was running before publishing anything.
void applyAssistProposal(AssistProject project, AssistProposal proposal)
{
    foreach (name; filenames)
    {
        auto path = buildPath(project.root, name);
        auto current = readAssistFile(path);
        auto original = project.files[name];
        if (current.present != original.present
                || current.contents != original.contents || assistSymlink(path ~ ".in"))
            fail("E_ASSIST",
                    name ~ " changed during generation; run assist again with the new contents");
    }
    string[] published;
    try
    {
        foreach (name; filenames)
            if (auto contents = name in proposal.files)
            {
                if (project.files[name].present && project.files[name].contents == *contents)
                    continue;
                atomicWrite(buildPath(project.root, name), *contents);
                published ~= name;
            }
    }
    catch (Exception error)
    {
        foreach_reverse (name; published)
        {
            auto path = buildPath(project.root, name);
            if (project.files[name].present)
                atomicWrite(path, project.files[name].contents);
            else
                remove(path);
        }
        throw error;
    }
}

private enum instructions = `You create and update Rattpack's two root files: Rattspec and Rattpkg.
Implement the user's request using the supplied existing files and source paths.
Preserve existing targets, dependencies, comments and project identity unless the request changes them.
Create both files if missing. Omit unchanged files from the response.
Return ONLY JSON in this shape:
{"files":{"Rattspec":"complete source","Rattpkg":"complete source"},"summary":"brief explanation"}
Only these two exact filenames are supported. Values must be complete file contents, not patches.

Rattscript is dynamically typed and tree-walked. Newlines or semicolons separate statements.
Named arguments use name: value, imports use import "module" (optionally as alias), bindings use let.
Lists use [a, b], maps use {key: value}, strings use double quotes. Use # for comments.

A root Rattspec calls project(name: "app", version: "1.0.0", kind: "single") exactly once.
Kinds: single, multi-module, monorepo. Declare at least one target with target.executable,
target.library, target.rule, target(), or rule(). Import "target" for member calls.
For example:
project(name: "app", version: "1.0.0", kind: "single")
import "fs"
import "target"
target.executable(name: "app", language: "cxx", sources: fs.glob("src/**/*.cpp"), flags: ["-O2"])
Languages: c, cxx, d. target.library uses shared: true for shared libraries.
Target fields: name, sources, language, output, shared, flags, include_dirs, link_flags, deps,
inputs, raw_inputs, headers, env, sandbox.
flags holds compiler flags, include_dirs holds search paths (lowercased, not includes),
link_flags holds linker arguments, and deps holds target handles or names of libraries to link.
rule(name: "generated", output: "build/generated.txt", command: ["program", "arg"]) declares a custom action.
Side effects such as fs.write and proc.run belong only in action blocks: action(targetHandle) { ... }.
Do not run commands during graph construction. Do not use wall clock, random values or network access in specs.
Subdirectory specs are automatically discovered as Rattspec.m with module(name: "sub"); never import them.
Nested independent projects require kind: "monorepo" and an explicit
monorepo { member "libs/one"; vendored "vendor/two"; ignore "old" } block.

A Rattpkg calls package(name: "app", version: "1.0.0", license: "MIT") exactly once.
Use the same name and version as the Rattspec. Dependencies use this syntax:
deps {
  dep "fmt" from: git("https://github.com/fmtlib/fmt.git"), tag: "11.0.2"
  dep "zlib" from: registry, version: "^1.3"
}
Sources: registry, git(url), http(url), ftp(url). Git requires exactly one tag: or rev: pin;
branch: requires a separate --allow-floating opt-in. HTTP/FTP require a real 64-hex sha256: checksum.
Prefer pinned Git dependencies when a registry package or archive checksum is not known.
Do not invent checksums or claim dependencies were fetched. Do not generate a lockfile.
Build specs access already resolved dependencies with import "pkg"; let library = pkg.get("fmt").
The returned package has path and version fields, not automatic target or link metadata.
Use import "path" and path.join(library.path, "include") with include_dirs for headers; declare
source/library targets explicitly when needed, since a dependency is not linked automatically.
Explain any required rattpkg resolve or follow-up build step in the summary.
`;
