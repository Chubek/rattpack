# 21. Structured data and text processing

[Previous: Collection pipelines](20-collection-pipelines.md) · [Contents](README.md) · [Next: Numeric reports](22-numeric-analysis.md)

`json`, `regex`, and `base64` add portable data interchange and text processing
to Rattscript. Their transformations are deterministic and can be used during
construction. File writes remain execution-time operations. Standalone blocks
below are independent programs; the final section combines them into a build.

## 21.1 Decode JSON into ordinary values

```ratt
import "json"

let document = json.parse('{"project":"widget","enabled":true,"versions":["1.0.0"],"note":null}')
assert(document.project == "widget")
assert(document.enabled == true)
assert(type(document.versions) == "list")
assert(document.note == nil)
assert(json.parse(json.stringify(document)) == document)
print(json.stringify(document))
```

Objects become maps with string keys, arrays become lists, and JSON null becomes
`nil`. Integers must fit signed 64-bit values. Decimal/exponent numbers become
floats and must be finite. Parsing follows strict RFC 8259 syntax, including
rejecting leading-zero integers, trailing non-whitespace text, and unquoted keys.

Encoding accepts paths as JSON strings. Sets, functions, target handles, and
other non-JSON kinds raise `E_TYPE`; transform those values into records first.
Malformed input, cycles, non-finite numbers, and excessive nesting raise
`E_RUNTIME`. Shared acyclic subcontainers can be encoded multiple times.

## 21.2 Distinguish missing fields from null

```ratt
import "json"
import "dict"

let settings = json.parse('{"compiler":{"flags":["-O2"],"optional":null}}')
assert(json.get(settings, ["compiler", "flags", 0]) == "-O2")
assert(json.get(settings, ["compiler", "missing"], "default") == "default")
assert(json.get(settings, ["compiler", "optional"], "default") == nil)
assert(json.get(settings, ["compiler", "flags", -1], "default") == "default")
assert(dict.get(settings.compiler, "optional", "default") == nil)
```

`json.get` traverses string object keys and nonnegative array indices. It returns
the fallback for a missing or incompatible step; it preserves a present null.
For required fields, ordinary member/index access plus annotations gives a
more direct contract: a missing key raises `E_NAME`, and a wrong kind raises
`E_TYPE` when it crosses an annotated binding.

## 21.3 Produce deterministic output

```ratt
import "json"

let first = {z: 2, a: {y: false, b: 1}}
let second = {a: {b: 1, y: false}, z: 2}
assert(json.stringify(first) == json.stringify(second))
assert(json.stringify(first) == '{"a":{"b":1,"y":false},"z":2}')
print(json.stringify(first, pretty: true))
```

Object keys are sorted recursively. List order is retained, so sort a list of
records explicitly when its input order is not the intended output order.
Pretty mode uses two-space indentation. Add a final newline yourself when the
destination file convention calls for one.

The display conversion `str(value)` is intended for messages. Use
`json.stringify` when the destination must be valid JSON, including escaped
strings and the distinction between `nil` and JSON null.

## 21.4 Extract fields with regular expressions

```ratt
import "regex" as re

let match = re.find("object widget size=128", "^object ([A-Za-z][A-Za-z0-9_]*) size=([0-9]+)$")
assert(match != nil, "invalid object record")
assert(match[0] == "object widget size=128")
assert(match[1] == "widget")
assert(int(match[2]) == 128)
assert(re.find("no size here", "[0-9]+") == nil)
assert(re.find("ac", "a(b)?c") == ["ac", ""])
```

`find` returns a capture list: zero is the complete match, and subsequent entries
are parenthesized groups. It returns `nil` when no match exists; an unmatched
optional group is an empty string. `find_all` returns a list of capture lists
for non-overlapping matches.

Patterns use Phobos regex syntax. Rattscript strings consume escapes before the
regex engine sees the pattern, so a regex backslash is doubled in source:

```ratt
import "regex" as re

assert(re.find("version=1.2", "([0-9]+)\\.([0-9]+)") == ["1.2", "1", "2"])
assert(re.test("RATTPACK", "^ratt", flags: "i"))
assert(re.replace("x=12;y=34", "([0-9]+)", "[$1]") == "x=[12];y=[34]")
assert(re.split("a, b; c", "[,;] *") == ["a", "b", "c"])
let literal = "release.+[candidate]"
assert(re.test(literal, "^" + re.escape(literal) + "$"))
```

Use `escape` when constructing a literal portion of a regex. Replacement `$1`,
`$2`, and later references select captured groups. Invalid patterns or flags
raise `E_RUNTIME`; the `i`, `m`, `s`, and `x` flags are described in chapter 6.

## 21.5 Exchange an encoded payload

```ratt
import "json"
import "base64"

let payload = {name: "widget", enabled: true, label: "λ雪"}
let wire = base64.encode(json.stringify(payload))
assert(json.parse(base64.decode(wire)) == payload)
assert(base64.encode("???", url_safe: true) == "Pz8_")
assert(base64.decode("Pz8_", url_safe: true) == "???")
assert(base64.decode(base64.encode("a\u0000b")) == "a\u0000b")
print(wire)
```

The encoder works on string bytes, preserving UTF-8 and embedded NULs. The
decoder returns bytes in a string. Both alphabets use RFC 4648 padding, including
`=` where required. Decoding requires canonical input: whitespace, missing or
excess padding, the wrong alphabet, and nonzero unused pad bits are errors.

Base64 decoding does not imply that the result is UTF-8 or JSON. Apply the
appropriate parser only when the payload's format is part of your data contract.

## 21.6 Normalize a declared JSON input

Create `data/records.json`:

```json
{"records":[{"name":" zeta ","version":"2.0.0"},{"name":" alpha ","version":"1.0.0"}]}
```

Complete `Rattspec`:

```ratt
project(name: "normalized-records", version: "1.0.0", kind: "single")
import "fs"
import "json"
import "str" as text
import "collections"
import "list" as sequence

fn normalize(record: map) -> map {
  let name: str = record.name
  let version: str = record.version
  return {name: text.trim(name), version: text.trim(version)}
}

let report = rule(name: "report", output: "build/records.json",
                  inputs: ["data/records.json"])
action(report) {
  let document = json.parse(fs.read("data/records.json"))
  let records: list = document.records
  let normalized = collections.map(records, normalize)
  let ordered = sequence.sort(normalized, fn(a, b) { return a.name < b.name })
  fs.write("build/records.json", json.stringify({records: ordered}, pretty: true) + "\n")
}
```

```sh
rattsc --lint Rattspec
rattbuild build report
```

The output contains `alpha` before `zeta`. The input is read inside the action
and listed in `inputs:`, so its bytes affect native incrementality. The normalizer
and embedded module helpers are captured with the action. Changing the helper
requires reconstructing/re-exporting a frozen graph; changing the data is an
execution-input change, subject to the graph's normal or strict replay policy.

For numeric fields and summary reports, continue to
[chapter 22](22-numeric-analysis.md).
