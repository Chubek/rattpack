# spec-drift: for-loop control escapes the evaluator

The Rattscript parser accepts `break` and `continue` in `for`/`foreach` bodies,
and the evaluator contains loop-control handlers for those bodies. Executing
either statement currently reaches the outer evaluator failure path instead
of completing loop control. This differs from the control-flow behavior implied
by the accepted language syntax and the evaluator implementation.

Reproduction with the 0.1.0 applications:

```sh
rattsc -e 'for value in [0, 1, 2] { if value == 1 { break } print(value) } print("after")'
rattsc -e 'for value in [0, 1, 2] { if value == 1 { continue } print(value) } print("after")'
```

Both commands print `0`, report
`<input>:1:1: E_RUNTIME: loop control outside a loop`, and exit with status 1.
Expected behavior is successful termination of the loop for `break`, or
continuation with value `2` for `continue`, followed by `after`.

The behavior was reproduced with LDC- and DMD-built application/runtime sets
during manual-example validation. Equivalent `while` loop control works.
The manual documents the current release limitation and uses verified examples.

Relevant implementation: `source/rattpack/script/evaluator.d`, the `for_`,
`break_`, `continue_`, and outer `run` handlers.

Recorded locally because this checkout has no configured Git remote/issue
tracker. This documentation change does not modify evaluator behavior.
