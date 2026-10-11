# Pipeline behaviors

Cross-cutting code that wraps every `send`.

## Overview

A ``PipelineBehavior`` has one generic method that receives the request and a `next`
continuation. Because the method is generic, one behavior type covers all requests with no
open-generic machinery. Mark it with ``Behavior()`` so discovery finds it.

```swift
@Behavior
struct Logging: PipelineBehavior {
    let logger: Logger
    func handle<R: Request>(_ request: R, next: Next<R>) async throws -> R.Response {
        logger.info("→ \(R.self)")
        let response = try await next(request)
        logger.info("← \(R.self)")
        return response
    }
}
```

## Ordering

`static var order: Int` decides nesting. Lower runs first, outermost. The default is 0.
Behaviors with equal order run in discovery order, which is binary layout order, so any
behavior that depends on another having run before it must say so with `order`.

```
Validation(-100) → FluentTransaction(-50) → Logging(0) → Retry(50) → Timing(100) → handler
```

## What a behavior can and cannot do

The types on both faces are fixed: `R` in, `R.Response` out. Within that, a behavior can:

- Short-circuit by throwing or by returning without calling `next` (caching, rejection).
- Replace the request value passed to `next`, of the same type (normalising input).
- Replace or transform the response (redaction, caching).
- Call `next` zero, one or many times (retries).
- Run work around the call (timing, logging, transactions, task-locals).
- Branch on runtime conformance: `if let v = request as? any Validatable`.

It cannot change the request type, add or remove behaviors for the current call, or choose
the handler. The chain is static; each link controls whether and how often the rest runs.

## Constraining a behavior to some requests

Use a marker protocol on the request and a runtime check in the behavior:

```swift
protocol Validatable { func validate() -> [String] }

@Behavior
struct Validation: PipelineBehavior {
    static var order: Int { -100 }
    func handle<R: Request>(_ request: R, next: Next<R>) async throws -> R.Response {
        if let v = request as? any Validatable {
            let problems = v.validate()
            if !problems.isEmpty { throw ValidationError(problems: problems) }
        }
        return try await next(request)
    }
}
```

## Retries

A behavior may call `next` again. Everything inside it, the handler included, runs once per
attempt, so retried handlers must be idempotent up to the point that can fail.

```swift
protocol Retryable { var maxAttempts: Int { get } }
extension Retryable { var maxAttempts: Int { 3 } }
protocol TransientError: Error {}
struct RetryExhausted: Error { let attempts: Int; let last: any Error }

@Behavior
struct Retry: PipelineBehavior {
    static var order: Int { 50 }
    func handle<R: Request>(_ request: R, next: Next<R>) async throws -> R.Response {
        guard let retryable = request as? any Retryable else { return try await next(request) }
        var attempt = 1
        while true {
            do {
                return try await next(request)
            } catch let error as any TransientError {
                guard attempt < retryable.maxAttempts else { throw RetryExhausted(attempts: attempt, last: error) }
                attempt += 1
                try await Task.sleep(for: .milliseconds(20 * attempt))
            }
        }
    }
}
```

Every exit from the loop leaves the function: success returns, a non-transient error
propagates, and an exhausted budget throws `RetryExhausted` so callers can tell a retried
failure from an immediate one.

## Just-in-time construction

The mediator constructs each component inside the behaviors that wrap it: the outermost
behavior first, each inner behavior when the one outside it calls `next`, and the handler
last. A behavior that sets a task-local around `next` therefore shapes how everything inside
is built. This is what lets <doc:FluentTransactions> hand the handler the transaction's
connection without any special support in the core. It also means construction errors
surface inside the pipeline, where logging and error-mapping behaviors see them.

## Behaviors and events

Behaviors wrap `send` only. `publish` has no pipeline; observe events with
``Mediator/Configuration/onEvent(_:)`` or a handler for `any Event`.
