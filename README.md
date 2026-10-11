# SwiftMediator

A MediatR-style mediator for Swift with **zero registration code**. Handlers and
pipeline behaviors are discovered at startup the same way Swift Testing discovers
`@Test` functions: a macro writes a small metadata record into a dedicated binary
section, and the mediator walks that section when it is created.

Three products:

| Product | Depends on | Dependencies for handlers |
|---|---|---|
| `SwiftMediator` | nothing at runtime | `Resolver` protocol; `SimpleResolver.shared` as the default root |
| `SwiftMediatorFactory` | `SwiftMediator` + [Factory](https://github.com/hmlongco/Factory) | `@Injected(\.keyPath)`; `Container.mediator` provided |
| `SwiftMediatorTesting` | `SwiftMediator` + Swift Testing | `.resolver` trait, `stub`, `EventRecorder`, `RequestRecorder` |

Both share the same handler protocols and the same `@Handler` / `@Behavior` macros.

### Core

```swift
import SwiftMediator

struct CreateUser: Request {
    typealias Response = User
    let name: String
}

@Handler
struct CreateUserHandler: RequestHandler {
    let repo: UserRepository          // init(resolver:) is synthesised; resolved by type

    func handle(_ request: CreateUser) async throws -> User {
        try await repo.insert(name: request.name)
    }
}

SimpleResolver.shared.register(UserRepository.self, lifetime: .singleton) { _ in UserRepository() }

let mediator = try Mediator()         // uses SimpleResolver.shared; throws on misconfiguration
let user = try await mediator.send(CreateUser(name: "Olaf"))
```

### With Factory

```swift
import SwiftMediatorFactory           // re-exports FactoryKit and SwiftMediator

extension Container {
    var userRepository: Factory<UserRepository> { self { UserRepository() }.singleton }
}

@Handler
struct CreateUserHandler: RequestHandler {
    @Injected(\.userRepository) private var repo    // nothing left for init(resolver:) to do

    func handle(_ request: CreateUser) async throws -> User {
        try await repo.insert(name: request.name)
    }
}

let mediator = Container.shared.mediator()            // singleton; scans the binary once
let user = try await mediator.send(CreateUser(name: "Olaf"))
```

Run `swift run Example` for the core version, `swift run OrderExample` for a fuller
Factory-based order-purchase flow (validation behavior, payment, event fan-out), and
`swift test` for all four suites.

### Requests without a typealias

A nested type named `Response` satisfies the associated type, so a request that owns its
response type needs no `typealias`:

```swift
struct PlaceOrder: Request {
    struct Response: Sendable { let orderID: String; let totalOre: Int }
    let customerEmail: String
}
```

Requests that answer with an existing type (`String`, `Order?`) still write
`typealias Response = Order?`.

## Mapping from MediatR

| MediatR | SwiftMediator |
|---|---|
| `IRequest<TResponse>` | `Request` with `associatedtype Response` |
| `IRequestHandler<TReq, TRes>` | `RequestHandler` with `associatedtype Req` |
| `INotification` / `INotificationHandler<T>` | `Event` / `EventHandler` |
| `IPipelineBehavior<TReq, TRes>` (open generic) | `PipelineBehavior` with a generic `handle<R>` method |
| `Behavior<,> where TReq : IValidatable` | `if let v = request as? any Validatable` inside `handle` |
| Assembly scanning | `@Handler` / `@Behavior` + binary-section walk |
| `IServiceProvider` | Core: `Resolver` protocol. Factory: `@Injected(\.keyPath)` |
| `services.AddMediatR(...)` | Core: `Mediator(resolver:)`. Factory: `Container.shared.mediator()` |
| `MakeGenericType` | Implicit existential opening of `any RequestHandler.Type` |

## How discovery works

`@Handler` on a top-level type expands to two things:

1. A member `init(resolver: any Resolver) throws` that resolves, by type, each stored
   property without a default value. Property-wrapped members such as `@Injected` and
   members with defaults are left alone. Skipped if the type declares `init(resolver:)`.
2. A peer global placed with `@section("__DATA_CONST,__swift5_mediatr") @used`:

   ```swift
   private let __mediator_record_CreateUserHandler: DiscoveryRecord = (
       kind: 1, reserved: 0,
       accessor: { Mediator.__erase(CreateUserHandler.self) }
   )
   ```

`Mediator.init` iterates every loaded Mach-O image, reads that section with
`getsectiondata`, calls each accessor to recover the type metadata, and casts it to
`any RequestHandler.Type`, `any EventHandler.Type` or `any PipelineBehavior.Type`.
The cast opens the existential into a generic registration function, which is where
the handler's `Req` type is read and keyed. Nothing is looked up by string.

Event handlers may declare `typealias Note = any UserEvent` to receive every event
conforming to that protocol, which is the equivalent of MediatR's covariant
notification handlers.

## Layout

```
Sources/SwiftMediator            core library (no runtime dependencies)
  Request.swift                  Request, Event
  Handlers.swift                 MediatorComponent, RequestHandler, EventHandler, PipelineBehavior, Next
  Resolver.swift                 Resolver, ResolverError, SimpleResolver
  Mediator.swift                 Mediator, Mediator.Configuration, MediatorError
  Macros.swift                   @Handler / @Behavior declarations
  Discovery/                     record layout and section walker
Sources/SwiftMediatorFactory     Factory binding
  Container+Mediator.swift       Container.mediator (.singleton), re-exports
  FactoryResolver.swift          Resolver backed by a Factory container
Sources/SwiftMediatorTesting     .resolver trait, EventRecorder, RequestRecorder
Sources/SwiftMediatorMacros      compiler plugin (DiscoverableMacro)
Sources/Example                  core demo with SimpleResolver
Sources/OrderExample             Factory-based order purchase flow demo
Tests/SwiftMediatorTests         core: dispatch, ordering, covariance, errors
Tests/SwiftMediatorTestingTests  .resolver trait, inherited roots, stubs, recorders
Tests/SwiftMediatorFactoryTests  Factory: .container trait, overrides, FactoryResolver
Tests/SwiftMediatorMacrosTests   XCTest: macro expansion snapshots and diagnostics
```

## The composition root (core)

`SimpleResolver.shared` is where an app's long-lived objects live. `Mediator()` with no
arguments uses it. Group registrations into modules so the root reads as a list:

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

| Layer | Examples | Lifetime |
|---|---|---|
| Infrastructure | network client, database, keychain | `.singleton` |
| Providers / repositories | `OrderAPI`, `UserProvider` | `.singleton` |
| Services | `PricingService`, validators | `.scoped` (or `.unique`) |
| Per-request state | `RequestContext`, `UnitOfWork` | `.scoped` |
| Handlers, behaviors | | per send, automatic |

The root is task-local. `SimpleResolver.$shared.withValue(other) { ... }` swaps it for the
duration of a task, which is how the `.resolver` test trait isolates tests. Libraries and
tests that want no global at all keep using `Mediator(resolver:)` with an explicit resolver.

`try resolver()` resolves with the type inferred from context, so factories read as
`OrderAPI(client: try r())`.

## Environments (core)

A resolver can have a parent. Lookups check the child first and fall back to the parent;
registrations never flow upward. Named layers make this convenient:

```swift
let root = SimpleResolver.processRoot
root.register(PaymentGateway.self, lifetime: .singleton) { _ in StripeGateway() }
root.register(PaymentGateway.self, in: .mock, instance: FakeGateway())   // root unchanged

try root.resolve(PaymentGateway.self)                    // StripeGateway
try root.environment(.mock).resolve(PaymentGateway.self) // FakeGateway
try root.environment(.mock).resolve(Mailer.self)               // falls back to root

try await SimpleResolver.using(.mock) {                        // switch the task-local shared root
    let mediator = try Mediator()                              // resolves through the mock layer
}
```

`.mock` and `.preview` are predefined; any string literal is a valid environment, and
layers nest (`root.environment(.mock).environment("offline")`). A layer owns the instances
it resolves: a singleton registered on the root and resolved through the mock layer is a
separate instance from the root's own, so switching environments never leaks state.

## Scopes and lifetimes (core)

Every `send` and `publish` runs inside one resolver scope. The handler and all behaviors
are resolved through that scope, so anything registered as `.scoped` is shared by them
for the duration of the call and released afterwards. That is the per-request lifetime
MediatR users get from their DI container's scoped services.

`SimpleResolver` supports three lifetimes:

```swift
resolver.register(Mailer.self) { _ in Mailer() }                                  // .unique: new on every resolve
resolver.register(UnitOfWork.self, lifetime: .scoped) { _ in UnitOfWork() }       // one per send / publish
resolver.register(Database.self, lifetime: .singleton) { _ in Database() }        // lazily created once
resolver.register(Config.self, instance: Config.load())                           // eager singleton
```

Factories receive the current scope's resolver, so their own dependencies follow the same
rules. Outside a scope, `.scoped` behaves like `.unique`.

Two types are injectable in every handler and behavior without registration:

- `Mediator` — the mediator doing the dispatch, bound to the current scope. A nested
  `send` or `publish` from a handler shares the outer call's `.scoped` instances, as a
  scoped DI container does in MediatR.
- `any Resolver` — the current scope, for resolving lazily.

Your own `Resolver` opts into scoping by implementing `withScope(_:)`. The default
implementation passes `self` through, which is correct for a resolver without lifetimes.

## Testing (`SwiftMediatorTesting`)

```swift
import Testing
import SwiftMediatorTesting

@Suite(.resolver) struct OrderTests {              // fresh SimpleResolver.shared per test
    @Test func placesOrder() async throws {
        SimpleResolver.shared.register(PaymentGateway.self, instance: PaymentGateway(declineAbove: .max))
        let events = EventRecorder()
        let mediator = try Mediator { config in
            config.stub(GetPrice.self) { _ in 42 }   // no GetPriceHandler or its dependencies needed
            config.record(events)                    // capture every published event
        }

        let c = try await mediator.send(PlaceOrder(customerEmail: "a@b.no", lines: lines))

        #expect(c.totalOre == 45_700)
        #expect(events.only(OrderPlaced.self) != nil)
    }
}
```

- `.resolver` gives each test an empty `SimpleResolver.shared`; tests run in parallel safely.
- `.resolver(inheriting: true)` makes each test a child of the enclosing root: it sees the
  enclosing registrations, owns its own singletons, and local registrations stay local.
- `.resolver(environment: .mock)` is the same through the enclosing root's mock layer, so
  mock registrations win and everything else falls back to the real wiring.
- `.resolver { root in ... }` seeds the root before each test.
- `Configuration.stub(Request.self) { ... }` answers a request with a closure, replacing any
  discovered handler. This is the `Mock<IMediator>` equivalent.
- `Configuration.exclude(Validation.self)` drops a discovered handler or behavior and ignores
  later registrations of it, so a test can bypass the pipeline or resolve a conflict.
- `SimpleResolver.shared.mock(PaymentGateway.self, with: FakeGateway())` is sugar for a
  protocol-keyed override; `mock(_:in: .mock, with:)` targets an environment layer instead.
- `EventRecorder` captures published events; `RequestRecorder` is a behavior that logs every
  request through the pipeline, nested ones included.
- Factory users keep using `FactoryTesting`'s `.container`; nothing here is needed there.

### Parallel testing

Swift Testing runs tests concurrently by default and nothing here opts out of that.

- `.resolver` swaps the task-local `SimpleResolver.shared` per test, so concurrent tests
  never share a root. The suite includes fifty parameterised cases and a hundred-task
  stress test that prove it.
- Discovery scans the binary once per process and caches the result, so parallel
  `Mediator()` calls do not contend on the scan. `DiscoverySection.rescan()` exists for
  the rare plugin-loaded-later case.
- The one way to break isolation is to register on `SimpleResolver.shared` from a test
  that does not use the trait: that mutates `SimpleResolver.processRoot`, which every
  other test shares. In debug builds, once any test has used `.resolver`, such a mutation
  records a test issue naming the offending test. Call
  `ResolverTrait.installProcessRootGuard()` early to arm it unconditionally.
- Tests that use an explicit `Mediator(resolver:)` with their own `SimpleResolver()` need
  no trait and are parallel-safe by construction.

## Factory integration (`SwiftMediatorFactory`)

- `Container.mediator` is a `.singleton` Factory provided by the library. Resolve it with
  `Container.shared.mediator()` or `@Injected(\.mediator)`. Handlers may inject the
  mediator to publish events.
- `FactoryResolver` bridges the core `Resolver` seam to Factory. Handlers that keep plain
  stored properties are resolved by type through Factory's opt-in `Resolving` protocol:
  add `extension Container: Resolving {}` and `container.register(MyService.self) { ... }`.
  Most Factory users will never need this and should prefer `@Injected`.
- **No per-send scope with Factory.** Factory's scopes (`.unique`, `.cached`, `.shared`,
  `.singleton`, `.graph`) are container-wide, and `.graph` covers a single resolution tree,
  while the mediator resolves the handler and each behavior as separate roots. Use the
  core's `.scoped` lifetime if you need an instance shared across one `send`.
- Handlers and behaviors are instantiated per `send` / `publish`, so their `@Injected`
  properties resolve from the **task-local** `Container.shared` at that moment. Scopes
  (`.singleton`, `.cached`, `.unique`) behave exactly as in any other Factory code.
- In tests, use `@Suite(.container)` from `FactoryTesting`. Each test gets a fresh
  container, overrides like `Container.shared.greeting.register { ... }` are visible to
  handlers, and tests run in parallel safely.

## Explicit registration

Discovery can be turned off, or combined with manual registration for types you
cannot annotate. Override the Factory to make that the app-wide mediator:

```swift
// Core
let mediator = try Mediator(resolver: resolver, discovery: false) { config in
    config.register(LegacyHandler.self)
    config.register(Logging.self)
}

// Factory
Container.shared.mediator.register {
    Mediator.failFast(resolver: FactoryResolver(Container.shared), discovery: false) { config in
        config.register(LegacyHandler.self)
    }
}
```

## Fail fast

`Mediator.init` throws `MediatorError` when the registry is wrong:

- `conflictingHandlers` — two handlers claim the same request type.
- `notAHandler` — a type is marked `@Handler` / `@Behavior` but conforms to none of the
  handler protocols.

With Factory, `Container.mediator` uses `Mediator.failFast`, which turns those errors into
a `fatalError` with the message on first resolution. A mediator with a broken registry
never reaches a request.

## Limitations and next steps

- **Darwin only for now.** The macro already emits an ELF section named
  `swift5_mediatr` on Linux, but `DiscoverySection` does not read it yet. The usual
  approach is a C shim exposing the linker's weak `__start_` / `__stop_` symbols.
  Windows PE is likewise unimplemented. Explicit registration works everywhere.
- **Handlers must be `Sendable`.** Structs and final classes are fine. A non-final class
  must declare `@unchecked Sendable`; the macro marks its `init(resolver:)` as `required`.
- **Top-level types only.** The peer record is a file-scope global, so `@Handler` on
  a nested type will not compile. Move the type to file scope.
- **Images loaded after `Mediator.init`** (plugins) are not seen. Add a
  `_dyld_register_func_for_add_image` callback if you need that.
- **Handlers and behaviors are instantiated per `send`**, matching MediatR's scoped
  lifetime. Share state across one call with a `.scoped` registration (core) or give
  dependencies a Factory scope.
- **Nested scopes are not supported.** A `send` issued from inside a handler through the
  injected `Mediator` reuses the outer scope. Calling the root mediator instance directly
  from a handler opens a new scope instead.
- Requires Swift 6.2 or later for the `@section` and `@used` attributes (SE-0492).
  Verified on Swift 6.4 / Xcode 27.
