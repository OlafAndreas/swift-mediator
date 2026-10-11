# Vapor integration

One-line routes with the `SwiftMediatorVapor` product, behind the `Vapor` trait.

## Routes

```swift
import SwiftMediatorVapor      // re-exports SwiftMediator

extension PlaceOrder: Content {}
extension PlaceOrder.Response: Content {}

app.post("orders") { req in try await req.send(PlaceOrder.self) }
app.get("orders", ":id") { req -> Order in
    guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
    guard let order = try await req.mediator.send(GetOrder(id: id)) else { throw Abort(.notFound) }
    return order
}
```

`req.send(Type.self)` decodes the body and dispatches; `req.sendQuery` does the same from the
query string. Behaviors see the decoded request, which middleware never can.

## Application and request

- `app.resolver` is the composition root, defaulting to ``SimpleResolver/processRoot``.
- `app.mediator` is built on first access with discovery on and fails fast on a broken
  registry. Assign your own to override, for example with stubs in tests.
- `app.configureMediator { $0.register(...) }` adds registrations, stubs or exclusions to
  the mediator `app.mediator` builds. `app.mediatorDiscovery` sets the policy.
- `req.mediator` binds the app's mediator to a child resolver seeded with the `Request`,
  its `Logger`, and whatever `app.seedRequests` added. Handlers take those as plain stored
  properties.

```swift
app.resolver.register(OrderStore.self, lifetime: .singleton) { _ in OrderStore() }
app.seedRequests { req, scope in
    scope.register(AuthenticatedUser.self) { _ in try req.auth.require(AuthenticatedUser.self) }
}
```

Singletons on `app.resolver` are shared across requests; per-request children see the same
instance.

## Naming

Vapor also has a `Request`. Keep domain types in a module that imports `SwiftMediator` only,
and write `SwiftMediator.Request` in files that import both.

## Testing

```swift
let app = try await Application.make(.testing)
app.resolver = SimpleResolver()
app.mediatorDiscovery = .thisModule()
app.post("echo") { req in try await req.send(Echo.self) }
try await app.testing().test(.POST, "echo", beforeRequest: { try $0.content.encode(Echo(text: "hei")) }) { res in
    #expect(res.status == .ok, "\(res.body.string)")
}
try await app.asyncShutdown()
```
