module rattpack_assist_opencode;

import rattpack.diagnostic : Diagnostic, Location, fail;
import rattpack.plugin.abi;
import rattpack.rt.sys : locateProgram;
import rattpack.script.evaluator : Evaluator;
import rattpack.script.value : Arguments, Value;
import rattpack.serialization : canonical, jsonObject;
import core.thread : Thread;
import core.time : seconds, msecs;
import std.conv : to;
import std.datetime.stopwatch : StopWatch;
import std.json : JSONType, JSONValue, parseJSON;
import std.process : Config, Redirect, kill, pipeProcess, tryWait, wait;
import std.stdio : File;
import std.string : indexOf, strip;

private RattPluginV1 plugin;

pragma(mangle, "rattpack_plugin_entry") export extern (D) RattPluginV1* rattpack_plugin_entry()
{
    plugin = RattPluginV1.init;
    plugin.kind = PluginKind.stdlib;
    plugin.name = "opencode-assist";
    plugin.registerModules = &registerModules;
    return &plugin;
}

private void registerModules(Evaluator evaluator)
{
    auto generate = evaluator.native("opencode.generate", (Arguments args, Location location) {
        if (evaluator.hermetic)
            fail("E_HERMETIC", "OpenCode IPC is unavailable in hermetic actions", location);
        auto executable = args.get("executable", 3, Value("opencode")).text(location);
        auto program = locateProgram(executable);
        if (!program.length)
            fail("E_ASSIST",
                "OpenCode executable not found: " ~ executable ~ "; install OpenCode V2 or use --opencode PATH",
                location);
        auto timeout = args.get("timeout", 5, Value(120)).integer(location);
        if (timeout <= 0 || timeout > int.max)
            fail("E_CLI", "OpenCode timeout must be a positive number of seconds", location);
        auto body = jsonObject();
        body["prompt"] = JSONValue(args.get("prompt", 0).text(location));
        auto model = args.get("model", 1, Value("")).text(location);
        if (model.length)
            body["model"] = modelReference(model, location);
        string[] command = [
            program, "api", "post", "/api/experimental/generate", "--data",
            canonical(body)
        ];
        auto server = args.get("server", 2, Value("")).text(location);
        if (server.length)
            command ~= ["--server", server];
        // A private server keeps assist independent of the shared background
        // service, so a busy or redirected session cannot affect this request.
        if (args.get("standalone", 4, Value(true)).truth)
            command ~= "--standalone";
        string output;
        if (evaluator.processRunner !is null)
        {
            auto result = evaluator.processRunner(command, evaluator.cwd);
            if (result.status)
                fail("E_ASSIST", "OpenCode API failed: " ~ result.output.strip, location);
            output = result.output;
        }
        else
            output = request(command, evaluator.cwd, cast(int) timeout, location);
        return Value(responseText(output, location));
    }, true);
    evaluator.modules["opencode"] = Value(["generate": generate]);
}

private JSONValue modelReference(string model, Location location) @safe
{
    auto slash = model.indexOf('/');
    auto hash = model.indexOf('#');
    auto end = hash < 0 ? model.length : cast(size_t) hash;
    if (slash <= 0 || cast(size_t) slash + 1 >= end || (hash >= 0 && end + 1 == model.length))
        fail("E_CLI", "model must be provider/model or provider/model#variant", location);
    auto reference = jsonObject();
    reference["providerID"] = JSONValue(model[0 .. slash]);
    reference["id"] = JSONValue(model[slash + 1 .. end]);
    if (hash >= 0)
        reference["variant"] = JSONValue(model[end + 1 .. $]);
    return reference;
}

private string responseText(string output, Location location) @safe
{
    try
    {
        auto response = parseJSON(output);
        if (response.type == JSONType.object)
            if (auto data = "data" in response.objectNoRef)
                if (data.type == JSONType.object)
                    if (auto text = "text" in data.objectNoRef)
                        if (text.type == JSONType.string && text.str.strip.length)
                            return text.str;
    }
    catch (Exception)
    {
    }
    fail("E_ASSIST", "invalid OpenCode V2 generation response; expected data.text", location);
    return null;
}

// Drain each pipe independently: diagnostics cannot corrupt the JSON on stdout,
// and neither pipe can block the child when its OS buffer fills.
private class Capture
{
    string text;
    bool overflow;
    Exception error;

    void read(File file)
    {
        enum limit = 4 * 1024 * 1024;
        try
        {
            ubyte[4096] buffer;
            while (true)
            {
                auto bytes = file.rawRead(buffer[]);
                if (!bytes.length)
                    break;
                if (text.length + bytes.length <= limit)
                    text ~= cast(string) bytes.idup;
                else
                    overflow = true;
            }
        }
        catch (Exception exception)
        {
            error = exception;
        }
    }
}

private string request(string[] command, string directory, int timeout, Location location)
{
    try
    {
        auto pipes = pipeProcess(command, Redirect.all, null, Config.none, directory);
        pipes.stdin.close;
        auto output = new Capture;
        auto errors = new Capture;
        auto stdoutReader = new Thread({ output.read(pipes.stdout); });
        auto stderrReader = new Thread({ errors.read(pipes.stderr); });
        bool reaped;
        scope (exit)
        {
            if (!reaped)
            {
                kill(pipes.pid);
                wait(pipes.pid);
            }
            stdoutReader.join;
            stderrReader.join;
            pipes.stdout.close;
            pipes.stderr.close;
        }
        stdoutReader.start;
        stderrReader.start;
        StopWatch clock;
        clock.start;
        int status;
        while (true)
        {
            auto result = tryWait(pipes.pid);
            if (result.terminated)
            {
                reaped = true;
                status = result.status;
                break;
            }
            if (clock.peek >= timeout.seconds)
                fail("E_ASSIST",
                        "OpenCode request timed out after " ~ timeout.to!string ~ " seconds",
                        location);
            Thread.sleep(20.msecs);
        }
        stdoutReader.join;
        stderrReader.join;
        if (output.error !is null)
            throw output.error;
        if (errors.error !is null)
            throw errors.error;
        if (output.overflow || errors.overflow)
            fail("E_ASSIST", "OpenCode response exceeded the 4 MiB IPC limit", location);
        if (status)
        {
            // The CLI writes the HTTP status to stderr and the API error body
            // to stdout. Keep both so the server's explanation is not lost.
            auto details = errors.text.strip;
            auto body = output.text.strip;
            if (body.length)
                details ~= (details.length ? "\n" : "") ~ body;
            fail("E_ASSIST", "OpenCode API exited with status " ~ status.to!string
                    ~ ": " ~ details, location);
        }
        return output.text;
    }
    catch (Diagnostic diagnostic)
    {
        throw diagnostic;
    }
    catch (Exception error)
    {
        fail("E_ASSIST", "cannot communicate with OpenCode: " ~ error.msg, location);
    }
    return null;
}
