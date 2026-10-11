# Fluent transactions

Wrap a handler in a database transaction with the `SwiftMediatorFluent` product, behind the
`Fluent` trait, which implies `Vapor`.

## Usage

```swift
struct PlaceOrder: Request, Transactional { ... }       // opt in per request

@Handler
struct PlaceOrderHandler: RequestHandler {
    let db: any Database                                // the transaction's connection
    func handle(_ request: PlaceOrder) async throws -> PlaceOrder.Response {
        try await Order(...).save(on: db)
        try await Ledger(...).save(on: db)              // throwing here rolls back both
        ...
    }
}

// configure.swift
app.useFluentTransactions()
```

## How it works

`useFluentTransactions()` registers the `FluentTransaction` behavior at order -50 and seeds
every request scope with `any Database`: the transaction's database inside the behavior,
otherwise `req.db`.

The behavior runs `req.db.transaction { }` around `next` and publishes the connection
through the `CurrentDatabase.transaction` task-local. Because the mediator constructs each
component just in time, inside the behaviors that wrap it, a handler built inside the
transaction sees that connection through its `let db: any Database` property. A handler for
a non-``Transactional`` request sees `req.db`. Event handlers published from within the
handler run in the same scope and the same transaction.

Order -50 keeps the transaction inside validation, so a rejected request opens none, and
outside logging and retries, so a retry gets a fresh transaction per attempt.

## Guarantees

Tests on an in-memory SQLite database prove commit on return, rollback on throw, that the
same handler without ``Transactional`` keeps its partial writes, and that the handler is
constructed inside the transaction.
