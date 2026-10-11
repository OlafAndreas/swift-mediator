<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Assets/wordmark-dark.svg">
    <img src="Assets/wordmark.svg" alt="SwiftMediator" width="440">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/OlafAndreas/swift-mediator/actions/workflows/ci.yml"><img src="https://github.com/OlafAndreas/swift-mediator/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-2F5F9E.svg" alt="MIT license"></a>
  <img src="https://img.shields.io/badge/Swift-6.2%2B-1B8A8F.svg" alt="Swift 6.2+">
  <img src="https://img.shields.io/badge/platforms-macOS%20%7C%20iOS%20%7C%20Linux-2F5F9E.svg" alt="macOS, iOS, Linux">
</p>

A MediatR-style mediator for Swift with **zero registration code**. Handlers and
pipeline behaviors are discovered at startup the same way Swift Testing discovers
`@Test` functions: a macro writes a small metadata record into a dedicated binary
section, and the mediator walks that section when it is created.

Four products, two of them behind package traits so that consumers who do not enable them
never fetch the dependency:

| Product | Depends on | Dependencies for handlers |
|---|---|---|
| `SwiftMediator` | nothing at runtime | `Resolver` protocol; `SimpleResolver.shared` as the default root |
| `SwiftMediatorFactory` (trait `Factory`) | `SwiftMediator` + [Factory](https://github.com/hmlongco/Factory) | `@Injected(\.keyPath)`; `Container.mediator` provided |
| `SwiftMediatorTesting` | `SwiftMediator` + Swift Testing | `.resolver` trait, `stub`, `EventRecorder`, `RequestRecorder` |
| `SwiftMediatorVapor` (trait `Vapor`) | `SwiftMediator` + [Vapor](https://vapor.codes) | `req.mediator`, `req.send(PlaceOrder.self)`, request-seeded values |
| `SwiftMediatorFluent` (trait `Fluent`, implies `Vapor`) | + [Fluent](https://github.com/vapor/fluent) | `FluentTransaction` behavior for `Transactional` requests |

```swift
// Consumer Package.swift: enable only what you use
.package(url: "https://github.com/OlafAndreas/swift-mediator", from: "0.1.0", traits: ["Vapor"])
```

Locally, `swift test --enable-all-traits` runs every suite; plain `swift test` runs the core
and testing suites only. Requires Swift 6.2 or later for the `@section` and `@used`
attributes. Verified on Swift 6.4 on macOS and Linux.

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

## Performance

`swift run -c release Benchmarks`, Apple M-series, Swift 6.4, one million iterations each:

| Operation | ns/op |
|---|---|
| direct handler call (baseline) | 0 |
| send, no behaviors | 267 |
| send, 3 pass-through behaviors | 484 |
| send, handler with 1 scoped dependency | 385 |
| publish, 1 matching handler | 292 |
| publish, 0 matching handlers | 37 |

What a `send` costs: one dictionary lookup, one scope object, a closure chain with one link
per behavior, and constructing the handler. Roughly a quarter of a microsecond, plus about
100 ns per behavior. A `publish` with no matching handler returns before opening a scope.
These are in-process numbers with trivial handlers; real handlers will dominate.

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

Discovery sees every record in every loaded image. Restrict it with a `Discovery` policy
when independent modules share a binary, which is what happens when SwiftPM links all
test targets into one bundle:

```swift
try Mediator(discovery: .thisModule())                 // this module's handlers only
try Mediator(discovery: .modules(["Orders", "Billing"]))
try Mediator(discovery: .none) { $0.register(...) }    // explicit only
app.mediatorDiscovery = .thisModule()                  // Vapor
```

## Layout

```
Sources/SwiftMediator            core library (no runtime dependencies)
  Request.swift                  Request, Event
  Handlers.swift                 MediatorComponent, RequestHandler, EventHandler, PipelineBehavior, Next
  Resolver.swift                 Resolver, ResolverError, SimpleResolver
  Mediator.swift                 Mediator, Mediator.Configuration, MediatorError
  Macros.swift                   @Handler / @Behavior declarations
  Discovery/                     record layout and section walker
Sources/SwiftMediatorVapor       Vapor binding (trait Vapor)
Sources/SwiftMediatorFactory     Factory binding (trait Factory)
  Container+Mediator.swift       Container.mediator (.singleton), re-exports
  FactoryResolver.swift          Resolver backed by a Factory container
Sources/SwiftMediatorTesting     .resolver trait, EventRecorder, RequestRecorder
Sources/SwiftMediatorSectionShim C shim for ELF section bounds (Linux)
Sources/SwiftMediatorMacros      compiler plugin (DiscoverableMacro)
Sources/Example                  core demo with SimpleResolver
Sources/OrderExample             Factory-based order purchase flow demo (trait Factory)
Sources/VaporExample             Vapor app: two routes, request-seeded values (trait Vapor)
Sources/SwiftMediatorFluent      FluentTransaction behavior, CurrentDatabase (trait Fluent)
Sources/Benchmarks               micro-benchmarks: swift run -c release Benchmarks
Tests/SwiftMediatorTests         core: dispatch, ordering, covariance, errors
Tests/SwiftMediatorTestingTests  .resolver trait, inherited roots, stubs, recorders
Tests/SwiftMediatorFactoryTests  Factory: .container trait, overrides, FactoryResolver
Tests/SwiftMediatorVaporTests    Vapor: routes through req.send, seeded scopes, overriding app.mediator
Tests/SwiftMediatorFluentTests   Fluent: commit, rollback, construction inside the transaction (SQLite)
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
layers nest (`root.environment(.mock).environment("offline")`). A singleton belongs to the
resolver it is registered on: a layer or a per-request child resolving a root singleton
gets the root's instance, and an override registered on the layer is the layer's own.
`copy()` flattens a chain into a standalone resolver with fresh singletons, which is what
the test trait uses so that no instance is ever shared between tests.

## Scopes and lifetimes (core)

Every `send` and `publish` runs inside one resolver scope. Components are constructed just
in time: the outermost behavior first, each inner behavior when the one outside it calls
`next`, and the handler last. A behavior that sets a task-local around `next` therefore
shapes how everything inside it is built, which is what makes transaction scoping possible
without any special support in the core. The handler and all behaviors
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
- `.resolver(inheriting: true)` gives each test a flattened copy of the enclosing root:
  same registrations, fresh singletons, local registrations stay local.
- `.resolver(environment: .mock)` copies the enclosing root's mock layer instead, so mock
  registrations win and everything else is the real wiring.
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

## Vapor integration (`SwiftMediatorVapor`, trait `Vapor`)

```swift
// Domain module: imports SwiftMediator only, so `Request` is unambiguous.
struct PlaceOrder: Request, Codable {
    struct Response: Codable, Sendable { let id: UUID }
    let customerEmail: String
}

@Handler
struct PlaceOrderHandler: RequestHandler {
    let store: OrderStore        // from app.resolver
    let logger: Logger           // pre-seeded from the Vapor request
    let user: AuthenticatedUser  // seeded by your app, see below
    func handle(_ request: PlaceOrder) async throws -> PlaceOrder.Response { ... }
}

// configure.swift
extension PlaceOrder: Content {}
extension PlaceOrder.Response: Content {}

app.resolver.register(OrderStore.self, lifetime: .singleton) { _ in OrderStore() }
app.seedRequests { req, scope in
    scope.register(Database.self, instance: req.db)
    scope.register(AuthenticatedUser.self, instance: try req.auth.require(AuthenticatedUser.self))
}

app.post("orders") { req in try await req.send(PlaceOrder.self) }
```

- `app.resolver` is the composition root (defaults to `SimpleResolver.processRoot`).
- `app.mediator` is built on first access with discovery on and fails fast on a broken
  registry. Assign your own to override, for example with stubs in tests.
- `req.mediator` binds the app's mediator to a child resolver seeded with the `Request`,
  its `Logger`, and whatever `app.seedRequests` adds. Handlers take those as plain stored
  properties.
- `req.send(PlaceOrder.self)` decodes the body and sends; `req.sendQuery` does the same from
  the query string. Behaviors see the decoded request, which middleware never can.
- Keep domain types in a module that imports `SwiftMediator` only. Vapor also has a
  `Request`, and a file importing both must write `SwiftMediator.Request`.
- Vapor's own `Validatable` is a better fit for a validation behavior than a custom marker.
- `app.configureMediator { $0.register(...) }` adds registrations, stubs or exclusions to
  the mediator `app.mediator` builds. Call it before the first access.

## Fluent transactions (`SwiftMediatorFluent`, trait `Fluent`)

```swift
struct PlaceOrder: Request, Transactional { ... }     // opt in per request

@Handler
struct PlaceOrderHandler: RequestHandler {
    let db: any Database                               // the transaction's connection
    func handle(_ request: PlaceOrder) async throws -> PlaceOrder.Response {
        try await Order(...).save(on: db)
        try await Ledger(...).save(on: db)             // throwing here rolls back both
        ...
    }
}

// configure.swift
app.useFluentTransactions()
```

`useFluentTransactions()` registers the `FluentTransaction` behavior at order -50 and seeds
every request scope with `any Database`: the transaction's database inside the behavior,
otherwise `req.db`. This works because the mediator constructs each component just in time,
inside the behaviors that wrap it. A handler built inside `req.db.transaction { }` sees the
transaction's connection through the `CurrentDatabase.transaction` task-local; a handler for a
non-`Transactional` request sees `req.db`. Event handlers published from within the handler
run in the same scope and the same transaction.

Tests use an in-memory SQLite database and prove commit on return, rollback on throw, and
that the same handler without `Transactional` keeps its partial writes.

## Factory integration (`SwiftMediatorFactory`, trait `Factory`)

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

## License

MIT. See [LICENSE](LICENSE).
