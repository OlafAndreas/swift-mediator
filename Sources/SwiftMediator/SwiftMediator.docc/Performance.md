# Performance

What a `send` costs.

## Numbers

`swift run -c release Benchmarks`, Apple M-series, Swift 6.4, one million iterations each:

| Operation | ns/op |
|---|---|
| direct handler call (baseline) | 0 |
| send, no behaviors | 267 |
| send, 3 pass-through behaviors | 484 |
| send, handler with 1 scoped dependency | 385 |
| publish, 1 matching handler | 292 |
| publish, 0 matching handlers | 37 |

## Where it goes

A `send` is one dictionary lookup, one scope object, a closure chain with one link per
behavior, and constructing the handler: roughly a quarter of a microsecond, plus about
100 ns per behavior. A `publish` with no matching handler returns before opening a scope.

These are in-process numbers with trivial handlers. Real handlers dominate. Discovery is
scanned once per process and cached, so building many mediators does not repeat the walk.

## Measuring correctly

Top-level code in `main.swift` is main-actor isolated in Swift 6, so every `await` there hops
executors and a naive harness measures the hop. The benchmark runs its body in a detached
task.
