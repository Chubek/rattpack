# 22. Numeric analysis and build reports

[Previous: Structured data and text](21-structured-data-and-text.md) · [Contents](README.md) · [Next: Release workflows](23-versioned-release-workflows.md)

The `math` and `stats` modules support checked integer calculations, portable
floating-point functions, and descriptive statistics. This chapter builds a
numeric report from an input file. Standalone blocks are independent programs.

## 22.1 Keep integer and floating-point intent explicit

```ratt
import "math"

assert(math.pow(2, 10) == 1024)
assert(type(math.pow(2, 10)) == "int")
assert(math.pow(2, -4) == 0.0625)
assert(math.gcd(-54, 24) == 6)
assert(math.lcm(6, 8) == 24)
assert(math.gcd(-9223372036854775808, 2) == 2)
assert(math.clamp(12, 0, 10) == 10)
```

Integer arithmetic is checked. Overflow raises `E_RUNTIME` instead of wrapping.
`pow` takes an integer exponent; negative exponents produce floating-point
reciprocals. `gcd` and `lcm` return nonnegative integers, and LCM is zero when
either operand is zero.

A `float` annotation accepts integers without converting their stored kind.
Consequently, `stats.sum([1, 2, 3])` can retain checked integer arithmetic. Use
explicit `float(value)` conversion when floating-point accumulation is intended.

## 22.2 Validate floating-point samples

```ratt
import "math"

fn finite_samples(values: list) -> list {
  let result = []
  for value in values {
    let number: float = value
    assert(math.is_finite(number), "sample must be finite")
    result.append(float(number))
  }
  return result
}

assert(finite_samples([1, 2.5, 3]) == [1.0, 2.5, 3.0])
assert(math.is_finite(1))
assert(not math.is_finite(float("nan")))
assert(not math.is_finite(float("inf")))
```

The annotation rejects strings and other nonnumeric kinds with `E_TYPE`; the
assertion makes this program's finite-data contract explicit. This validation
is useful for values computed by other scripts as well as parsed input.

Native `sqrt`, rounding, logarithm/exponential, and trigonometric functions
require finite arguments and finite results. Invalid domains such as `sqrt(-1)`
or `log(0)` raise `E_RUNTIME`.

```ratt
import "math"

assert(math.sqrt(9) == 3)
assert(math.floor(-1.2) == -2)
assert(math.ceil(-1.2) == -1)
assert(math.round(-1.5) == -2)
assert(math.abs(math.sin(math.pi / 2) - 1) < 0.000000000001)
assert(math.abs(math.log(math.e) - 1) < 0.000000000001)
```

Rounding returns floating-point integral values; `round` sends half-way ties
away from zero. Trigonometric arguments are in radians. Tolerances make intent
clear when checking calculations with floating-point rounding.

## 22.3 Choose a summary statistic

```ratt
import "stats"

let samples = [10, 2, 4, 8]
assert(stats.sum(samples) == 24)
assert(stats.mean(samples) == 6)
assert(stats.median(samples) == 6)
assert(stats.quantile(samples, 0) == 2)
assert(stats.quantile(samples, 0.25) == 3.5)
assert(stats.quantile(samples, 1) == 10)
assert(samples == [10, 2, 4, 8])
```

Mean is the arithmetic average. Median is the quantile at 0.5; an even-sized
list interpolates its two middle values. Quantiles sort numerically and evaluate
position `(n - 1) * q`, interpolating the neighboring entries. The original list
order is preserved.

For `[10, 20, 30, 40, 50]`, the 95th percentile is 48 under this interpolation
rule. Other tools may use different quantile definitions; record the definition
when comparing reports.

## 22.4 Population and sample variance

```ratt
import "stats"
import "math"

assert(math.abs(stats.variance([1, 2, 3]) - 2.0 / 3) < 0.000000000001)
assert(stats.variance([1, 2, 3], sample: true) == 1)
assert(stats.stdev([1, 1, 1]) == 0)
assert(stats.variance([42]) == 0)
assert(stats.variance([1000000000001.0, 1000000000002.0, 1000000000003.0],
                      sample: true) == 1)
```

Population variance divides by n; sample variance divides by n - 1. The
implementation uses Welford's recurrence rather than subtracting two large
squared sums. `stdev` takes the square root of the selected variance.

| Operation | Minimum input size |
| --- | --- |
| `sum` | Zero; empty sum is integer zero |
| `mean`, `median`, `quantile` | One |
| Population `variance` / `stdev` | One |
| Sample `variance` / `stdev` | Two |

Undersized input or a quantile outside `[0, 1]` raises `E_RUNTIME`. A report
that accepts an empty dataset should define its own explicit empty result
before invoking those operations.

## 22.5 Generate a timing report

Create `data/timings.json`:

```json
{"samples_ms":[12,10,14,11,13]}
```

Complete `Rattspec`:

```ratt
project(name: "timing-report", version: "1.0.0", kind: "single")
import "fs"
import "json"
import "math"
import "stats"

fn summarize(values: list) -> map {
  assert(len(values) > 0, "at least one timing is required")
  let numbers = []
  for value in values {
    let number: float = value
    assert(math.is_finite(number) and number >= 0, "timings must be finite and nonnegative")
    numbers.append(float(number))
  }
  return {count: len(numbers), mean_ms: stats.mean(numbers),
          median_ms: stats.median(numbers), p95_ms: stats.quantile(numbers, 0.95),
          variance_ms2: stats.variance(numbers), stdev_ms: stats.stdev(numbers)}
}

let report = rule(name: "report", output: "build/timings.json",
                  inputs: ["data/timings.json"])
action(report) {
  let document = json.parse(fs.read("data/timings.json"))
  let result = summarize(document.samples_ms)
  fs.write("build/timings.json", json.stringify(result, pretty: true) + "\n")
}
```

```sh
rattsc --lint Rattspec
rattbuild build report
```

The supplied dataset has mean and median 12 ms, population variance 2 ms²,
and a 95th percentile of 13.8 ms. The report preserves units in field names
and uses population variance. Its source data is an ordinary tracked input;
the action computes summaries rather than measuring wall-clock time during
graph construction.

For a measurement tool, run it in a preceding action and make its JSON output
an input or dependency of this report. The producer/consumer pattern is in
[chapter 8](08-actions-and-graphs.md). To share the summarizer between a
standalone program and build specs, move it into a source module as shown in
[chapter 24](24-writing-rattscript-libraries.md).
