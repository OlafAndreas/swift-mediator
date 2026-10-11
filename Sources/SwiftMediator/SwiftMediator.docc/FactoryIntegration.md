# Factory integration

Use Factory for dependencies with the `SwiftMediatorFactory` product, behind the `Factory`
trait.

## Handlers

Declare dependencies with `@Injected`. The generated `init(resolver:)` skips property-wrapped
members, so it has nothing to resolve.

```swift
import SwiftMediatorFactory     // re-exports FactoryKit and SwiftMediator

extension Container {
    var userRepository: Factory<UserRepository> { self { UserRepository() }.singleton }
}

@Handler
struct CreateUserHandler: RequestHandler {
    @Injected(\.userRepository) private var repo
    @Injected(\.mediator) private var mediator
    func handle(_ request: CreateUser) async throws -> User { ... }
}

let mediator = Container.shared.mediator()      // singleton; scans the binary once
```

## What the binding provides

- `Container.mediator`, a `.singleton` Factory. Resolve it with `Container.shared.mediator()`
  or `@Injected(\.mediator)`. It uses `Mediator.failFast`, which terminates with the message
  on a configuration error since Factory closures cannot throw.
- `FactoryResolver`, which bridges the core ``Resolver`` seam to Factory's opt-in `Resolving`
  protocol for handlers that keep plain stored properties. Add `extension Container: Resolving {}`
  and `container.register(MyService.self) { ... }`. Most Factory users should prefer `@Injected`.

## Scopes

Factory's scopes (`.unique`, `.cached`, `.shared`, `.singleton`, `.graph`) apply as usual.
There is no per-send scope on the Factory side: Factory scopes are container-wide, and
`.graph` covers a single resolution tree while the mediator resolves the handler and each
behavior as separate roots. Use the core's `.scoped` lifetime if you need an instance shared
across one `send`.

## Testing

`FactoryTesting`'s `.container` trait isolates each test. Handlers created inside `send`
resolve from the task-local container, so overrides reach them. Scope discovery to the test
module by registering the mediator per test:

```swift
@Suite(.container) struct OrderTests {
    init() {
        Container.shared.mediator.register {
            Mediator.failFast(resolver: FactoryResolver(Container.shared), discovery: .thisModule())
        }
    }
}
```

## With Vapor

Both traits combine. Use `@Injected` for app-wide services and let per-request values arrive
as plain stored properties seeded by `app.seedRequests`; the macro handles the mix.
