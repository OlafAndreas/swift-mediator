# Handlers

Request handlers, event handlers, and what the `@Handler` macro generates.

## Request handlers

A ``RequestHandler`` names its request type through `Req` and implements one method. Mark
it with ``Handler()`` so discovery finds it.

```swift
@Handler
struct GetPriceHandler: RequestHandler {
    let catalog: Catalog
    func handle(_ request: GetPrice) async throws -> Int {
        try await catalog.price(for: request.sku)
    }
}
```

## Event handlers

An ``EventHandler`` names its event type through `Note`. `Note` is deliberately
unconstrained so a handler can subscribe to a protocol existential and receive every
conforming event:

```swift
@Handler
struct AuditTrail: EventHandler {
    func handle(_ event: any OrderEvent) async throws {
        print("audit: \(type(of: event)) \(event.orderID)")
    }
}
```

## What the macro generates

`@Handler` and `@Behavior` expand to two things you never see in source:

1. An initialiser `init(resolver: any Resolver) throws` that resolves, by type, each stored
   property without a default value. Property-wrapped members such as Factory's `@Injected`
   and members with defaults are left alone. If the type declares `init(resolver:)` itself,
   nothing is added.
2. A discovery record placed in a dedicated binary section; see <doc:HowDiscoveryWorks>.

For `PlaceOrderHandler` in <doc:GettingStarted>, the generated initialiser is:

```swift
init(resolver: any Resolver) throws {
    self.repository = try resolver.resolve((OrderRepository).self)
    self.payments = try resolver.resolve((PaymentGateway).self)
    self.mediator = try resolver.resolve((Mediator).self)
}
```

The parentheses exist so that `any Protocol` types work: `resolve((any OrderStore).self)`.

## Always-available dependencies

Two types resolve in every handler and behavior without registration:

- ``Mediator``: the mediator doing the dispatch, bound to the current scope. A nested `send`
  or `publish` from a handler shares the outer call's scoped instances.
- `any Resolver`: the current scope, for resolving lazily.

## Rules

- Handlers must be `Sendable`. Structs and final classes are fine. A non-final class has to
  declare `@unchecked Sendable`, and the macro marks its initialiser `required`.
- Handlers may be nested in other types. The record then becomes a `static let` on the
  enclosing type, which is not possible inside a generic type or a function body; the macro
  says so.
- Handlers are instantiated per `send` and per `publish`, inside the behaviors that wrap
  them. Keep construction cheap and keep state in your dependencies.

## Handlers in front of an existing service

When the state lives in a service or actor that already exists, each handler is a thin
adapter: it maps the request's fields onto one method call.

```swift
@Handler
struct CancelOrderHandler: RequestHandler {
    let orders: OrderService

    func handle(_ request: CancelOrder) async throws {
        try await orders.cancel(id: request.orderID, reason: request.reason)
    }
}
```

That is the expected shape. The mapping line is the part only you can write. The rest gives
discovery a type to find and lets you test or replace the handler on its own, while behaviors
wrap it like any other. A request whose `Response` is `Void` needs no return.

A service cannot be the handler for several requests itself: `RequestHandler` names one
`Req`, and a type conforms to a protocol only once. Keep the handlers small and the state in
the service.

## Explicit registration, stubs and exclusions

Discovery can be turned off or combined with explicit configuration:

```swift
let mediator = try Mediator(discovery: .none) { config in
    config.register(LegacyHandler.self)
    config.register(Logging.self)
    config.stub(GetPrice.self) { _ in 42 }       // answer a request with a closure
    config.exclude(Validation.self)              // drop a discovered behavior or handler
}
```

`stub` replaces any handler for that request and suppresses later registrations. `exclude`
removes a discovered or registered handler or behavior and ignores later registrations of
it, which also resolves a conflict between two handlers.
