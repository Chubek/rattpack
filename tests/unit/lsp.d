module tests.lsp;

import unit_threaded;
import rattpack.lsp.analysis : Document, staticSource;
import rattpack.lsp.catalog : Catalog, moduleNames;
import rattpack.lsp.text;
import std.algorithm : canFind;
import std.exception : assertThrown;
import std.path : absolutePath, buildPath;

@("LSP positions and edits use UTF-16 across Unicode and line endings")
unittest
{
    auto text = "a😀雪\r\nsecond\n";
    offsetAt(text, Position(0, 3)).shouldEqual(5);
    positionAt(text, 8).shouldEqual(Position(0, 4));
    positionAt(text, 10).shouldEqual(Position(1, 0));
    positionAt(text, text.length).shouldEqual(Position(2, 0));
    offsetAt(text, Position(0, 999)).shouldEqual(8);
    applyEdit(text, Position(0, 1), Position(0, 3), "β").shouldEqual("aβ雪\r\nsecond\n");
    assertThrown(offsetAt(text, Position(0, 2)));
    assertThrown(applyEdit(text, Position(1, 0), Position(0, 0), ""));
    positionAt("a\rb", 2).shouldEqual(Position(1, 0));
    offsetAt("a\rb", Position(1, 1)).shouldEqual(3);
}

@("LSP file URIs round trip escaped and non-ASCII path bytes")
unittest
{
    auto path = absolutePath(buildPath("a space", "雪#100%.ratt"));
    auto uri = uriFromPath(path);
    assert(uri.canFind("%20") && uri.canFind("%23") && uri.canFind("%25"));
    pathFromURI(uri).shouldEqual(path);
    pathFromURI("untitled:example").shouldEqual("");
}

@("LSP static indexing respects nested scopes, parameters and shadowing")
unittest
{
    auto text = `let value = 1
fn example(x = value, value: int = 2) -> int {
  let inside = value
  return inside + x
}
print(value)
`;
    auto document = new Document("untitled:scopes.ratt", text);
    assert(document.diagnostic is null);
    auto inside = offsetAt(text, Position(3, 12));
    auto nested = document.scope_.at(inside);
    auto value = nested.resolve("value", inside);
    assert(value !is null && value.detail == "value: int");
    positionAt(text, value.start).shouldEqual(Position(1, 22));
    auto parameter = offsetAt(text, Position(1, 23));
    assert(document.scope_.at(parameter).resolve("value", parameter) is value);
    assert(nested.resolve("inside", inside) !is null);
    auto outside = text.length;
    assert(document.scope_.at(outside).resolve("inside", outside) is null);
    document.scope_.resolve("value", outside).detail.shouldEqual("let value: int");
}

@("LSP template masking is static and keeps diagnostic byte offsets")
unittest
{
    auto text = "@if env.has(\"x\")\nlet x = @{proc.run([\"false\"])}\n@else\nlet x = 1\n@end\n"
        ~ "let name = \"@{env.get(\"user.name\")}\"\n";
    auto masked = staticSource(text, "example.ratt.in", true);
    masked.length.shouldEqual(text.length);
    auto document = new Document("untitled:example.ratt.in", text);
    assert(document.diagnostic is null);
    auto invalid = new Document("untitled:example.ratt.in", "let x = @{1 + 2");
    invalid.diagnostic.code.shouldEqual("E_TEMPLATE");
}

@("LSP catalog includes public signatures from every embedded library")
unittest
{
    auto catalog = new Catalog;
    foreach (name; moduleNames)
        assert(name in catalog.modules, name);
    auto items = catalog.modules["json"];
    assert(items.canFind!(item => item.name == "stringify"
            && item.detail.canFind("pretty: bool = false")));
    assert(!items.canFind!(item => item.name == "_native"));
}
