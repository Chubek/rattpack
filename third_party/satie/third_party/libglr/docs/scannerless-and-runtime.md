# Scannerless parsing, selections, semantic actions, and runtime storage

All APIs are available through `<glr/glr.h>` and their individual public headers.
`examples/calc.c` is a complete calculator using the new APIs:

```sh
./build/examples/calc '12.5 + 2 * (3 - 1)'
# Result: 16.5
```

## Terminal patterns

`glr_scannerless_set_pattern(grammar, terminal_id, expression, error, size)`
attaches a POSIX extended regular expression to a terminal. Supported syntax
includes character classes, alternation, groups, `?`, `*`, `+`, and bounded
repetition. Matching is anchored at the current cursor. The expression and
compiled matching state are grammar-owned. A failed replacement preserves the
previous pattern and writes a diagnostic when a buffer is supplied.

For example, `[0-9]+` matches each nonempty digit prefix. If the input is `123`,
the GLR engine considers lengths 1, 2, and 3 and continues every viable parse
path. Different terminals can match the same text. Grammar alternatives, rather
than terminal-registration order, decide which readings survive. Regex
alternatives yielding the same terminal and endpoint share one terminal node.

Patterns accepting the empty string are rejected. Express empty syntax through
an epsilon production. Regex matching is POSIX text matching: classes follow
the process's regex locale, and an embedded NUL terminates the text available to
a regex. `glr_scannerless_set_literal()` supports exact length-delimited binary
literals, including embedded NULs. Pattern input uses the byte driver and byte
offsets, bypassing UTF-16 auto-detection. Existing reader/lexer hooks continue to
serve the UTF-16 driver for grammars using default literal-name tokenization.

Unconfigured terminals retain literal-name matching.
`glr_scannerless_clear_pattern()` restores that behavior. Patterns activate
scannerless execution automatically. `glr_parser_set_scannerless(parser, true)`
also explores all literal alternatives for grammars without patterns; otherwise
literal-only grammars keep their longest-match behavior.

`glr_scannerless_scan()` returns an allocated array of every match at a byte
offset. Free the array with `free()`. `glr_scannerless_match()` provides the
longest prefix of an individual terminal. Neither function reads beyond the
provided input length. Trivia configured with `glr_parser_set_trivia()` is
skipped before terminal matching.

## Selecting the production body

A selection context contains a production, its ordered matched children,
optional child values, and the original input. An action receives this as
`context->selection`. `glr_select()` recognizes:

| Selector | Meaning |
| --- | --- |
| `$1`, `$2`, ... | One-based position in the production body |
| `$lhs`, `$rhs`, ... | Alias assigned with `glr_production_set_alias()` |
| `$LEXEME` | The sole terminal of a single-terminal production |

Aliases identify occurrences, so two positions containing the same grammar
symbol can have different aliases. Aliases are unique per production, use
`[A-Za-z_][A-Za-z0-9_]*`, and cannot be `LEXEME`. Passing NULL clears an alias.
The grammar's string pool owns alias text.

A `glr_selection_t` exposes the matched forest node, its semantic value, and a
`lexeme`/`length` slice of the input. Non-terminal selections expose the complete
matched span as well. Slices are borrowed and are not necessarily NUL-terminated.
An invalid selector returns -1 and clears the selection. Ordered positions are
preserved even when repeated epsilon occurrences share the same forest node.

## Deferred semantic actions

An action registered with `glr_production_set_semantic_action()` receives the
selection context and writes an opaque pointer through `void **value`. Its
return value is zero on success. `action_data` is separate from the parser's
`user_data`; an optional destructor owns action data after successful
registration and is called when the action is replaced, cleared, or removed
with its production. Re-registering the same data pointer transfers its
ownership to the replacement action.

Parsing builds the SPPF without running callbacks. After acceptance, when the
grammar has registered actions, evaluation proceeds in two passes:

1. Resolve every chosen packed alternative, validate the derivation, and detect
   cycles using an explicit DFS stack and a hash map.
2. Evaluate bottom-up, memoizing each shared constructor within that evaluation.

An ambiguous symbol requires a `glr_semantic_resolver_fn`, configured by
`glr_parser_set_semantic_resolver()`. The resolver returns the zero-based index
of a constructor under that symbol, or `SIZE_MAX` to reject the choice.
Unresolved ambiguity, invalid derivations, and cycles invoke no semantic
callbacks. Callback failure stops evaluation and reports
`GLR_SEMANTIC_ERROR_ACTION`. Allocation failures report
`GLR_SEMANTIC_ERROR_MEMORY`.

`glr_parse_result_t.semantic_value` carries the start-production value.
`semantic_error` describes an evaluation failure, while `error` is
`GLR_PARSE_ERROR_SEMANTIC`. The parser retains the accepted forest for inspection
even if evaluation fails. `glr_semantic_evaluate()` is also available to evaluate
a forest explicitly with a different resolver or application context.

Without an action, a unary production forwards its child's value; a terminal's
default value is its node; empty and multi-symbol productions default to their
constructor node. Those node values are borrowed from the forest. Custom values
are application-owned, and libglr never frees them. Applications should keep
their intermediate values alive through evaluation and release them on both
success and error. The calculator demonstrates one application-owned list of
stable value cells. Evaluation does not store values in forest nodes, allowing
independent evaluations and forest clones.

## String pool

`glr_stringpool_create()` creates a length-aware intern pool backed by klib's
`khash` and `kalloc`. Both lookup and arena allocation are protected by a mutex.
`glr_stringpool_intern()` accepts C strings; `glr_stringpool_intern_n()` accepts
arbitrary byte strings, including empty strings and embedded NULs. Equal byte
strings return the same pointer. Every entry has an extra terminating NUL.

Pointers remain stable across growth until pool destruction. Use
`glr_stringpool_count()` and `glr_stringpool_bytes()` for statistics; byte counts
include the terminator once per distinct entry. Pool destruction requires that
all users have finished. Interned text is immutable and must not be freed
individually.

Grammars own a pool for symbol names and production aliases. Rewrite and query
renames intern new names, preserving pattern ownership. Removing symbols and
productions releases their patterns/actions, and destroys the pool when the
grammar itself is destroyed. Grammar transformations that create new
productions require registering the desired aliases/actions on those new
productions.

## Threading

`glr_thread_pool_create(n)` starts persistent pthread workers. Submit callbacks
with `glr_thread_pool_submit(pool, callback, data)`. Submission is asynchronous;
`glr_thread_pool_wait()` waits until the queue and active work are empty, and
`glr_thread_pool_destroy()` drains queued work and joins every worker. A mutex
and condition variables protect the CTL vector-based FIFO. Callbacks may submit
additional work, but must not wait on or destroy their own pool. Callback data
must remain alive until the work completes.

`glr_parallel_for(n, count, callback, data)` is a synchronous indexed loop using
klib's work-stealing `kt_for`. Each index is executed once, with a worker id in
`[0, n)`. Worker counts are between 1 and 256; excess workers are reduced when
there are fewer indices. Independent invocations may run concurrently. The
vendored loop uses atomic reads for work stealing and executes work on the
calling thread if creating a worker fails.

Share a read-only grammar between independently created parsers. A parser's
mutable execution state belongs to one calling thread. GSS entry reference
counts are atomic so independent stacks can retain and release shared entries.
The library links `Threads::Threads`; its installed headers expose no klib/CTL
container types.

## GLR storage and incremental behavior

The parser runs immutable stack configurations through a cursor-ordered CTL
agenda. Each LR action forks the original configuration, preserving both
shift/reduce and reduce/reduce alternatives. klib hash tables deduplicate full
configurations, including ordered stack entries, forest pointers, lookahead,
token width, and cursor. Configurations at completed offsets are released.

Terminals are packed by their full spans. Constructors are packed by production,
span, and ordered children: different splits of the same production over the
same span remain separate alternatives. Forest cloning, traversal, ambiguity
detection, and destruction use dynamic visited sets and iterative walks, retaining
sharing and handling cycles. Public arrays remain available as views of the
underlying geometric-capacity vectors.

Live sessions reuse snapshots for deterministic literal parses. Pattern grammars
and ambiguous forests are rebuilt during edits because a token can grow across
the old lexical boundary and a single snapshot cannot capture every alternative.
The incremental forest API also uses a complete parse for pattern grammars and
grammars with semantic actions. This ensures callbacks only see complete
accepted inputs. A manual `glr_parser_parse_from()` resume requires a valid
snapshot and a boundary that the edit cannot change.

Generated parse tables are refreshed when the grammar's structure changes;
explicitly supplied tables remain caller-configured. Compile-time public struct
layouts have grown, so rebuild clients against the new headers.
