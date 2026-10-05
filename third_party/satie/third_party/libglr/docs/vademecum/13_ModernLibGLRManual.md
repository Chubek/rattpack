# Chapter 13: The Modern LibGLR Manual

## 13.1 Purpose and scope

This chapter is the practical reference for the current LibGLR API. The earlier
chapters explain GLR theory and the original parser substrate; this chapter
shows how to assemble the newer pieces into a production parser:

- scannerless terminals and lexer hooks;
- parse-table construction and parser configuration;
- SPPF inspection, traversal, cloning, and XML export;
- selection aliases and deferred semantic actions;
- live and incremental parsing for editors;
- persistent cache and dependency invalidation;
- binary serialization and cache-safe transport;
- S-expression queries and AST construction;
- grammar rewriting and the GLRpp C++20 façade;
- graph and thread-pool utilities.

The public C API is declared in `include/glr/*.h`. Applications may include the
umbrella header:

```c
#include <glr/glr.h>
```

Individual headers are preferable for libraries that want a narrow dependency
surface. Every object created by a `glr_*_create`, `glr_*_open`, `glr_*_compile`,
or deserialize function has a matching destroy or close function documented in
the same header.

## 13.2 Build and link

LibGLR is a C11 library. A typical CMake consumer links the exported target:

```cmake
find_package(libglr CONFIG REQUIRED)
add_executable(my_parser main.c)
target_link_libraries(my_parser PRIVATE libglr::libglr)
```

For a source-tree build:

```sh
cmake -S . -B build -DBUILD_TESTS=ON
cmake --build build -j
ctest --test-dir build --output-on-failure
```

The persistent cache is optional and is enabled with `-DENABLE_CACHE=ON` when
its storage dependency and OpenSSL are available. The core parser, live parser,
diff, query, scannerless, forest, and serialization APIs do not require the
persistent cache.

GLRpp is header-only and requires C++20:

```cmake
add_executable(my_cpp_parser main.cpp)
target_link_libraries(my_cpp_parser PRIVATE GLRpp libglr)
target_compile_features(my_cpp_parser PRIVATE cxx_std_20)
```

## 13.3 Runtime model and ownership

A LibGLR application normally has this shape:

```text
grammar -> parser -> parse forest -> queries / semantics / serialization
                         |
                         +-> live editing and persistent cache
```

The grammar owns symbols, productions, terminal patterns, aliases, semantic
registrations, and any grammar-owned parse table. A parser borrows its grammar.
A live parser owns its text and current forest but borrows its grammar. A cache
owns its database and serialized entries but never owns the grammar or an input
buffer.

Destroy objects in reverse dependency order: live parser, parser, cache, then
grammar. If a forest must outlive its parser, call `glr_parser_take_forest()` or
`glr_forest_clone()`; do not retain an ordinary parse-result forest after its
parser has been destroyed.

All offsets and lengths in the C API are byte offsets. Line and column helpers
use one-based line numbers and one-based byte columns.

## 13.4 Grammar construction and validation

Create symbols with `glr_grammar_add_symbol()` and productions with
`glr_grammar_add_production()`:

```c
#include <glr/grammar.h>

glr_grammar_t *grammar = glr_grammar_create();
int expr = glr_grammar_add_symbol(grammar, GLR_SYMBOL_NONTERMINAL, "Expr");
int number = glr_grammar_add_symbol(grammar, GLR_SYMBOL_TERMINAL, "n");
int plus = glr_grammar_add_symbol(grammar, GLR_SYMBOL_TERMINAL, "+");

glr_symbol_t *body[3] = {
    glr_grammar_get_symbol(grammar, expr),
    glr_grammar_get_symbol(grammar, plus),
    glr_grammar_get_symbol(grammar, number)
};
int production = glr_grammar_add_production(grammar, expr, body, 3);
(void)production;
glr_grammar_set_start_symbol(grammar, expr);
```

A zero-length body is an epsilon production. Use `glr_grammar_validate()` before
building a parse table when a grammar came from a file, plugin, or network.
Lookup and count helpers include:

- `glr_grammar_get_symbol()` and `glr_grammar_get_production()`;
- `glr_grammar_find_symbol()` and `glr_grammar_find_symbol_any()`;
- `glr_grammar_symbol_count()` and `glr_grammar_production_count()`.

Pointers returned by the grammar are borrowed. Adding symbols or productions may
reallocate internal arrays, so do not cache array addresses across mutations.

### 13.4.1 Parse tables

`glr_parse()` builds a table lazily. Applications that want validation,
conflict reporting, or table reuse can build one explicitly:

```c
char error[256] = {0};
glr_parse_table_t *table =
    glr_grammar_build_parse_table(grammar, error, sizeof error);
if (table == NULL) {
    fprintf(stderr, "cannot build table: %s\n", error);
} else {
    printf("%zu conflict cells\n",
           glr_parse_table_conflict_count(table));
    glr_grammar_set_parse_table(grammar, table, true);
}
```

Passing `true` transfers table ownership to the grammar. Passing `false` keeps
ownership with the caller. A parser can also receive an override through
`glr_parser_set_parse_table()`.

## 13.5 Parsing and parse results

```c
#include <glr/parser.h>

glr_parser_t *parser = glr_parser_create(grammar);
glr_parse_result_t result = glr_parse(parser, input, input_length);
if (result.error != GLR_PARSE_SUCCESS) {
    fprintf(stderr, "parse failed at byte %zu\n", result.position);
} else {
    /* result.forest is valid while parser owns it */
}
```

A result contains an error code, forest, byte position, optional user data,
and semantic value/status. Success means that the accepting state was reached;
a non-null intermediate forest is not itself proof of success.

Useful parser configuration and inspection functions are:

```c
glr_parser_set_trivia(parser, " \t\r\n");
glr_parser_set_scannerless(parser, true);
glr_parser_set_user_data(parser, application_state);
glr_parser_get_error(parser);
glr_parser_get_forest(parser);
glr_parser_stack_count(parser);
```

`glr_parser_reset()` clears transient state. `glr_parser_take_forest()` transfers
the current forest to the caller. `glr_forest_clone()` makes an independent deep
copy without changing parser ownership.

## 13.6 SPPF forests and GSS state

The parse result is a Shared Packed Parse Forest, not an ordinary tree. Its
nodes are:

- `GLR_NODE_TERMINAL`: a matched terminal span;
- `GLR_NODE_NONTERMINAL`: a symbol occurrence over a span;
- `GLR_NODE_CONSTRUCTOR`: one production reduction and ordered children.

The root is the accepted start-symbol node. Traverse shared nodes once with
`glr_forest_visit()`:

```c
static void visit(glr_forest_node_t *node, size_t depth, void *data)
{
    (void)data;
    printf("%*s symbol=%d span=[%zu,%zu)\n",
           (int)(depth * 2), "", node->symbol_id,
           node->position, node->end_position);
}

glr_forest_visit(forest, forest->root, visit, NULL);
```

`glr_forest_total_nodes()`, `glr_forest_node_count_at()`,
`glr_forest_node_is_terminal()`, `glr_forest_node_is_nonterminal()`, and
`glr_forest_is_ambiguous()` are useful null-safe inspection helpers.

For tooling and tests, forests can be assembled directly with
`glr_forest_get_terminal()`, `glr_forest_get_symbol()`,
`glr_forest_get_constructor()`, and `glr_forest_pack_production()`. Reductions
must be keyed by the full production and span; using only a start offset breaks
left-recursive grammars.

The graph-structured stack is exposed through `stack.h`. A parser snapshot is a
whole stack configuration, not merely its top entry. This matters when a later
reduction pops several entries and resumes from the state below them.

## 13.7 Scannerless terminals

Attach a POSIX extended regular expression to a terminal with
`glr_scannerless_set_pattern()`:

```c
int number = glr_grammar_add_symbol(grammar, GLR_SYMBOL_TERMINAL, "NUMBER");
char error[128] = {0};
glr_scannerless_set_pattern(grammar, number, "[0-9]+",
                            error, sizeof error);
```

Matching is anchored at the current cursor. Non-empty matching prefixes are
retained, so a pattern may yield multiple viable lengths for GLR exploration.
Expressions that accept the empty string are rejected. Pattern installation is
atomic: a failed replacement preserves the previous pattern.

Use `glr_scannerless_set_literal()` for exact length-delimited literals,
including embedded NUL bytes. Unconfigured terminals retain literal-name
matching, and `glr_scannerless_clear_pattern()` restores that behavior.

Standalone inspection is useful for editors and diagnostics:

```c
glr_terminal_match_t *matches = NULL;
size_t count = 0;
glr_scannerless_scan(grammar, input, length, cursor, &matches, &count);
for (size_t i = 0; i < count; ++i)
    printf("terminal=%d length=%zu\n", matches[i].symbol_id, matches[i].length);
free(matches);
```

`glr_scannerless_match()` returns the longest prefix for one terminal. Both
functions are bounded by the supplied input length. `glr_parser_set_trivia()`
continues to apply before matching where the parser's byte driver supports it.

## 13.8 Lexer hooks

Lexer hooks customize terminal discovery, especially for the UTF-16 reader:

```c
static bool classify_at(const glr_lexer_event_t *event,
                        glr_lexer_response_t *response, void *data)
{
    (void)data;
    if (event->codepoint != '@')
        return false;
    glr_lexer_response_accept(response, "at", event->default_bytes_consumed);
    return true;
}

glr_lexer_hooks_t *hooks = glr_lexer_hooks_create();
glr_lexer_hooks_add(hooks, "at-sign", 100, classify_at, NULL, NULL);
glr_parser_set_lexer_hooks(parser, hooks);
```

Hooks run in priority order. A hook must accept a response and consume at least
the default byte count to win. Otherwise the next hook or normal reader behavior
is used. The parser does not take ownership of the registry; detach or destroy
objects according to the parser and registry lifetimes.

Use `glr_lexer_hooks_dispatch()` for unit tests and
`glr_lexer_response_reset()`/`glr_lexer_response_accept()` for explicit response
management. `glr_lexer_unicode_name()` provides the bundled Unicode name used by
the default reader path.

## 13.9 Disambiguation

When a grammar has multiple valid readings, GLR keeps packed alternatives.
Disambiguation hooks can resolve or reject candidates. Standard hook factories
cover precedence, associativity, predicates, scores, and longest match.

A custom hook receives `glr_disambig_context_t`, including the parser, grammar,
forest, ambiguous parent, candidate array, lookahead symbol, and candidate
count. Prefer context helpers over direct state mutation:

```c
glr_disambig_context_reject_candidate(context, index);
glr_disambig_context_select_candidate(context, index);
```

Hook priorities let narrow policies run before general fallbacks. Once a hook is
successfully registered with `glr_parser_add_disambiguator()`, ownership is
transferred to the parser. On registration failure, the caller must destroy the
hook.

## 13.10 Selection aliases and semantic actions

### 13.10.1 Aliases and selections

Production aliases make semantic code independent of raw child indexes. Aliases
are one-based and local to a production:

```c
glr_production_set_alias(grammar, production, 1, "left");
glr_production_set_alias(grammar, production, 2, "operator");
glr_production_set_alias(grammar, production, 3, "right");
```

A `glr_select_context_t` can resolve `$1`, `$left`, or `$LEXEME`:

```c
glr_selection_t selected = {0};
if (glr_select(&context, "$left", &selected) == 0) {
    /* selected.value is opaque; selected.lexeme is borrowed */
}
```

`$LEXEME` requires exactly one terminal in the production. Lexemes are borrowed
length-delimited slices and are not guaranteed to be NUL-terminated.

### 13.10.2 Deferred semantic actions

Semantic actions run bottom-up after a derivation has been selected. Returned
values are opaque caller-owned pointers; LibGLR never destroys them:

```c
static int make_number(const glr_semantic_context_t *context,
                       void **value, void *data)
{
    (void)data;
    glr_selection_t selected = {0};
    if (glr_select(&context->selection, "$LEXEME", &selected) != 0)
        return -1;
    long *number = malloc(sizeof *number);
    if (number == NULL)
        return -1;
    *number = strtol(selected.lexeme, NULL, 10);
    *value = number;
    return 0;
}
```

Register it with `glr_production_set_semantic_action()`. The registration's
destroy callback destroys action data, not the semantic value. Evaluate a forest
explicitly with `glr_semantic_evaluate()` and handle its argument, memory,
ambiguity, cycle, and action error codes.

No callbacks run for an unresolved or invalid derivation. This makes semantic
evaluation safe to retry after a disambiguator or query has selected a different
reading.

## 13.11 Live and incremental parsing

The live parser owns a copy of the document, current forest, edit metadata, and
reuse statistics. It borrows the grammar:

```c
char error[256] = {0};
glr_live_parser_t *live = glr_live_parser_create(
    grammar, text, text_length, error, sizeof error);
```

An initial failure returns null because no valid tree exists. Later failures are
reported by `glr_live_parser_error()` and
`glr_live_parser_get_stats()` while the current forest becomes unavailable.

### 13.11.1 Edits

Edit positions use one-based lines and byte columns. The end is exclusive:

```c
glr_live_edit_t edit = {
    .start_line = 3, .start_column = 8,
    .end_line = 3, .end_column = 9,
    .replacement = "x", .replacement_length = 1
};
glr_live_parser_edit(live, &edit, error, sizeof error);
```

The text splice is immediate, but the forest remains old until
`glr_live_parser_update()`. Batch edits and update once. Use
`glr_live_parser_has_pending_edits()` to avoid no-op updates.

`glr_live_parser_set_text()` replaces the whole document. The session exposes
`glr_live_parser_text()`, `glr_live_parser_forest()`, dirty-node inspection, and
`glr_live_parser_last_edit_range()` for editor integrations.

### 13.11.2 Statistics and coordinates

```c
glr_live_parser_stats_t stats;
glr_live_parser_get_stats(live, &stats);
printf("reparsed=%llu reused=%llu nodes=%zu\n",
       (unsigned long long)stats.bytes_reparsed,
       (unsigned long long)stats.bytes_reused,
       stats.total_nodes);
```

Statistics include edit/update counts, the last reused/reparsed byte split,
dirty-node count, input length, total nodes, and parse success. Lexical
boundaries and grammar structure can expand the reparsed region beyond the
literal edit.

Use `glr_live_offset_of()` and `glr_live_line_column_of()` instead of duplicating
line-index logic. Invalid coordinates are rejected rather than silently
clamped.

## 13.12 Text diffs

`diff.h` computes a minimal single-span edit between two buffers:

```c
glr_edit_t edit;
if (glr_compute_edit(old_text, old_length,
                     new_text, new_length, &edit) == 0) {
    printf("old=[%zu,%zu) new=[%zu,%zu)\n",
           edit.old_start, edit.old_end,
           edit.new_start, edit.new_end);
}
```

The descriptor distinguishes insertion, deletion, and replacement. Use
`glr_edit_old_length()`, `glr_edit_new_length()`, and `glr_edit_is_empty()` for
range calculations. The common-prefix and common-suffix helpers are independent
of grammars and can be used by a larger editor diff algorithm.

## 13.13 Persistent cache and dependencies

### 13.13.1 Cache lifecycle

The optional cache stores serialized forests, GSS nodes, and subtree payloads:

```c
glr_cache_config_t config = GLR_CACHE_DEFAULT_CONFIG;
config.mdbx_path = ".cache/my-language";
config.ttl_seconds = 7 * 24 * 60 * 60;

glr_cache_t *cache = glr_cache_open(&config);
```

Call `glr_cache_sync()` before a controlled shutdown and `glr_cache_close()`
exactly once. A parser can use `glr_parser_set_cache()` for incremental support.

Forest keys combine a SHA-256 content hash, grammar version, and start symbol:

```c
glr_forest_cache_key_t key = {0};
glr_cache_compute_hash((const uint8_t *)text, length, key.content_hash);
key.grammar_crc = grammar_version;
key.start_symbol = (uint32_t)start_symbol;
```

Use `glr_cache_lookup_forest()` and `glr_cache_store_forest()` for complete
forests. GSS keys add state and position. Subtree keys combine source hash,
production id, and grammar version. Lookup results distinguish hit, miss, and
error.

### 13.13.2 Invalidation

Record byte-range dependencies and invalidate overlaps:

```c
glr_dependency_add(cache, key_id, GLR_CACHE_ENTRY_FOREST, start, end);
glr_dependency_invalidate_range(cache, edit_start, edit_end);
```

`glr_dependency_get_affected()` returns a separately allocated list released by
`glr_dependency_free_list()`. `glr_cache_get_stats()` reports hit/miss rates and
storage counts; `glr_cache_clear()` and `glr_cache_vacuum()` are useful for
maintenance.

## 13.14 Serialization and XML

Serialize a forest to an allocated binary buffer:

```c
uint8_t *data = NULL;
size_t length = 0;
if (glr_serialize_forest(forest, &data, &length) == 0) {
    write(fd, data, length);
    free(data);
}
```

Restore it with `glr_deserialize_forest()`. Stack nodes and individual forest
nodes have matching functions. The format has magic tags, versions, sizes,
counts, and offsets; deserializers validate those fields. Never trust serialized
offsets by casting untrusted bytes directly to header structures.

The serialization API also exposes XML event output. Event sinks avoid building a
large intermediate string and are appropriate for diagnostics and network
responses:

```c
static void emit(glr_xml_event_t event, const char *text,
                 size_t length, void *data)
{
    FILE *out = data;
    if (event == GLR_XML_TEXT)
        fwrite(text, 1, length, out);
}

glr_forest_write_xml_events(forest, emit, stdout);
```

Use `glr_forest_to_xml()` for small outputs and event streaming for large ones.

## 13.15 Queries and ASTs

Queries are S-expressions pairing forest patterns with named actions:

```scheme
(query
  (name "symbols")
  (rules
    (match (terminal _) (print-symbol))))
```

Compile with `glr_query_compile()`, run with `glr_query_run()`, or use
`glr_query_run_ex()` for reporting, AST output, mutable grammar options, and
statistics. The query and pattern compilers reject malformed input and unknown
actions.

### 13.15.1 Patterns

| Pattern | Meaning |
| --- | --- |
| `(terminal NAME)` | terminal with a named symbol |
| `(nonterminal NAME)` | non-terminal with a named symbol |
| `(constructor ID)` | constructor for a production |
| `_` | wildcard of the expected kind |
| `(any NAME)` | any node with that symbol |
| `$name` or `@name` | bind the matched node |

Nested patterns match ordered children. A pattern naming three children must
match three children in order; it is not an unordered set match.

### 13.15.2 Actions and ASTs

Built-in actions cover extraction, printing, counting, AST node/leaf creation,
XML output, rejection, halt, signaling, and related integration tasks. Add
application actions to a caller-owned table with
`glr_query_actions_register()`. Local actions shadow global actions of the same
name.

ASTs are plain trees rather than shared forests. Create with `glr_ast_create()`
or parse with `glr_ast_from_sexp()`. Inspect using `glr_ast_root()`,
`glr_ast_count_nodes()`, and `glr_ast_find()`. Render with
`glr_ast_to_sexp()` or stream with `glr_ast_write()`. AST ownership includes
names, values, and child nodes; inspection pointers are borrowed.

## 13.16 Rewriting and transformation pipelines

Grammar rewriting should happen before parse-table construction and must preserve
validation invariants. GLRpp provides native duplicate-removal and sorting
passes, an optional Equinox e-graph pass, and syntax-level rule compilation:

```cpp
glrpp::rewrite::RewritePipeline pipeline;
pipeline.add_once(glrpp::rewrite::native::remove_duplicate_productions());
pipeline.add_fixed_point(
    glrpp::rewrite::equinox::equivalent_rhs_dedup(), 8);

glrpp::Grammar optimized = grammar.rewritten(pipeline);
```

Passes should be idempotent after convergence, return `false` when unchanged,
and preserve production metadata, aliases, precedence, associativity, and
semantic registrations. Always bound fixed-point iteration and validate the
rewritten grammar.

## 13.17 Graphs and parallel work

`graph.h` supplies a general directed graph container for visualization,
dependency analysis, and forest adapters:

```c
glr_graph_t *graph = glr_graph_create();
int left = glr_graph_add_node(graph, left_data);
int right = glr_graph_add_node(graph, right_data);
glr_graph_add_edge(graph, (size_t)left, (size_t)right, symbol_id);
```

Node and edge counts are null-safe. Removing edges does not remove nodes;
`glr_graph_clear()` preserves the graph object. The graph never owns arbitrary
`data` pointers, so applications free payloads separately.

`thread.h` provides a small pool and parallel-for helper for independent
application work. Prefer one parser per thread and immutable shared grammar data.
Do not mutate one grammar, parser, cache transaction, or forest concurrently
unless the relevant API documents that operation as safe.

## 13.18 GLRpp C++20 reference

Include the header-only façade with:

```cpp
#include <GLRpp/GLRpp.hpp>
```

Grammar and parser construction is value-oriented:

```cpp
glrpp::Grammar grammar;
auto expr = grammar.nonterminal("Expr");
auto number = grammar.terminal("n");
grammar.add_production(expr, {number});
grammar.set_start(expr);

glrpp::Parser parser(grammar);
auto result = parser.try_parse("n");
```

The modern façade includes:

| C++ API | C subsystem |
| --- | --- |
| `glrpp::Forest` | owned SPPF and cloning |
| `glrpp::serialize()` / `deserialize_forest()` | binary forest serialization |
| `glrpp::LiveParser` | live edit/update sessions |
| `glrpp::compute_edit()` | byte diff computation |
| `glrpp::Scannerless` | terminal scanning helpers |
| `glrpp::LexerHooks` | hook registry ownership |
| `glrpp::Cache` | cache lifecycle and hashing |
| `glrpp::Query` | query compilation and execution |
| `glrpp::Ast` | AST ownership and S-expressions |
| `glrpp::Graph` | graph ownership and mutation |

Move-only RAII handles own C resources. `ParseTree`, forest nodes, query
contexts, and lexeme slices are borrowed views whose lifetime follows the C API.
Expected grammar/configuration failures use `dsl::Result`; construction failures
throw exceptions. Do not catch and ignore a parse error merely because a forest
pointer is non-null.

## 13.19 End-to-end editor architecture

A robust language-server integration can follow this lifecycle:

```text
startup:
  create grammar
  install productions, aliases, patterns, semantic actions
  validate grammar and build table
  open optional cache

open document:
  create live parser with initial text
  attach cache if enabled
  compile reusable queries and AST definitions

on edit:
  convert line/column to byte offsets
  report one or more live edits
  update once
  publish diagnostics and reuse statistics
  run queries over the current forest
  evaluate semantics only for a valid selected derivation

shutdown:
  synchronize and close cache
  destroy live parser, parser, and grammar in that order
```

A failed update is a valid editor state: retain the current text, show
`glr_live_parser_error()`, and treat a null current forest as “not currently
parseable,” not as a process failure.

## 13.20 Robustness checklist

- Validate external grammars and serialized data.
- Bound every input by an explicit byte length.
- Reject empty scannerless regexes and invalid edit coordinates.
- Treat query and AST S-expressions as untrusted input when appropriate.
- Set cache map sizes and TTLs for the deployment.
- Do not share mutable parsers or forests across threads without synchronization.
- Destroy resources in reverse dependency order.
- Check every allocation and negative C return value.
- Keep semantic values caller-owned and type-safe.
- Bound rewrite fixed points and validate rewritten grammars.

## 13.21 API map

| Task | Header |
| --- | --- |
| grammar, symbols, productions | `grammar.h` |
| parser and parse results | `parser.h` |
| ambiguity hooks | `disambiguate.h` |
| SPPF creation and traversal | `forest.h` |
| stack snapshots and GSS | `stack.h` |
| scannerless terminals | `scannerless.h` |
| reader customization | `reader.h`, `lexer-hooks.h` |
| aliases and selections | `select.h` |
| deferred semantics | `semantic-action.h` |
| live editing | `live-parsing.h` |
| byte diffs | `diff.h` |
| persistent cache | `cache.h`, `dependency.h` |
| binary/XML serialization | `serialization.h` |
| forest queries and ASTs | `query.h` |
| grammar rewrites | `rewrite.h` |
| graph utilities | `graph.h` |
| parallel application work | `thread.h` |
| C++20 façade | `GLRpp/GLRpp.hpp` |

For conceptual background, read Chapters 1–4. For grammar and parser
construction, read Chapters 5–7. For rewriting, disambiguation, serialization,
and incremental parsing, read Chapters 8–11 and use this chapter as the modern
API cross-reference.
