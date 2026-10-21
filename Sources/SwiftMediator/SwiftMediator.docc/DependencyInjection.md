# Dependency injection

The resolver seam, the shared root, lifetimes and modules.

## The seam

``Resolver`` is one method: `resolve(type)`. Handlers and behaviors receive a resolver in
their generated `init(resolver:)`. Anything that can produce instances by type can sit
behind it. ``SimpleResolver`` is the built-in implementation; the Factory binding supplies
another.

`try resolver()` resolves with the type inferred from context, so factories read naturally:

```swift
resolver.register(OrderAPI.self, lifetime: .singleton) { r in OrderAPI(client: try r()) }
```

## The shared root

``SimpleResolver/shared`` is the app's composition root. `Mediator()` with no arguments
uses it. It is task-local: `SimpleResolver.$shared.withValue(other) { }` swaps it for the
duration of a task, which is how the test trait isolates tests. ``SimpleResolver/processRoot``
is the value in effect when nothing has swapped it.

Group registrations into ``ResolverModule``s so the root reads as a list:

```swift
struct NetworkingModule: ResolverModule {
    func register(into resolver: SimpleResolver) {
        resolver.register(NetworkClient.self, lifetime: .singleton) { _ in NetworkClient() }
        resolver.register(OrderAPI.self, lifetime: .singleton) { r in OrderAPI(client: try r()) }
    }
}

SimpleResolver.shared.install(NetworkingModule(), OrdersModule())
let mediator = try Mediator()
```

Libraries and tests that want no global keep using `Mediator(resolver:)` with their own
resolver.

## Lifetimes

| ``Lifetime`` | Instances |
|---|---|
| `.unique` | a new one on every resolve (the default) |
| `.scoped` | one per `send` or `publish`, shared by the handler and all behaviors |
| `.singleton` | one, created lazily, for the lifetime of the resolver |

`register(_:instance:)` is an eager singleton. Factories receive the resolver of the current
scope, so their own dependencies follow the same rules. Outside a scope, `.scoped` behaves
like `.unique`.

A rough layering for an app:

| Layer | Examples | Lifetime |
|---|---|---|
| Infrastructure | network client, database, keychain | `.singleton` |
| Providers, repositories | `OrderAPI`, `UserProvider` | `.singleton` |
| Services | `PricingService`, validators | `.scoped` or `.unique` |
| Per-request state | `RequestContext`, `UnitOfWork` | `.scoped` |
| Handlers, behaviors | | per send, automatic |

## Protocol-keyed registration

Register an implementation under its protocol and depend on the protocol only. The bare
protocol name and `(any P).self` are the same key.

```swift
resolver.register(PaymentGateway.self, lifetime: .singleton) { _ in StripeGateway() }

@Handler
struct PlaceOrderHandler: RequestHandler {
    let payments: any PaymentGateway
    ...
}
```

## Parents and children

A ``SimpleResolver`` may have a parent. Lookups check the child first and fall back up the
chain; registrations never flow upward. Singletons belong to the resolver they are registered
on, so a child sees the parent's instance. See <doc:Environments> for named layers, and
<doc:ScopesAndLifetimes> for what a `send` does with this.

## Async dependencies

``Resolver`` factories are synchronous, and so is `init(resolver:)`. A dependency that only
exists after an `await` cannot be a factory. There are two ways to provide one.

Register the actor that owns it, and await inside `handle`:

```swift
resolver.register(SessionStore.self, lifetime: .singleton) { _ in SessionStore() }

@Handler
struct ListOrdersHandler: RequestHandler {
    let sessions: SessionStore
    func handle(_ request: ListOrders) async throws -> [Order] {
        let session = try await sessions.current()
        ...
    }
}
```

Or await at the call site and pass the value with ``Mediator/send(_:with:)``. Those
registrations are visible to this call only, including nested `send` and `publish` calls
from its handlers. Everything else resolves through the mediator's own resolver and scopes:

```swift
let session = try await sessions.current()
let orders = try await mediator.send(ListOrders()) {
    $0.register(Session.self, instance: session)
}
```

The first keeps handlers in charge of their dependencies. The second suits a value the
caller already holds, such as a client for the account the caller is serving.
