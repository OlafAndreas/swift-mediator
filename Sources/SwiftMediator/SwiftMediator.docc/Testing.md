# Testing

Isolated roots, stubs and recorders with the `SwiftMediatorTesting` product.

## The resolver trait

`@Suite(.resolver)` gives each test an empty, task-local ``SimpleResolver/shared``, so tests
can register fakes freely and run in parallel. Variants:

- `.resolver(inheriting: true)`: a flattened copy of the enclosing root, same registrations,
  fresh singletons.
- `.resolver(environment: .mock)`: a copy of the enclosing root's mock layer, so mock
  registrations win and everything else is the real wiring.
- `.resolver { root in ... }`: seed the root before each test.

Traits nest. A suite-level trait can install the app's modules once, and individual tests
choose a layer.

```swift
import Testing
import SwiftMediatorTesting

@Suite(.resolver(inheriting: true)) struct OrderTests {
    @Test func declinedPayment() async throws {
        SimpleResolver.shared.mock(PaymentGateway.self, with: DecliningGateway())
        let mediator = try Mediator(discovery: .thisModule())
        await #expect(throws: OrderError.self) { try await mediator.send(PlaceOrder(...)) }
    }
}
```

## Stubs and recorders

```swift
let events = EventRecorder()
let requests = RequestRecorder()
let mediator = try Mediator(discovery: .thisModule()) { config in
    config.stub(GetPrice.self) { _ in 42 }     // no GetPriceHandler or its dependencies needed
    config.exclude(Validation.self)            // bypass a behavior
    config.record(events)                      // capture every published event
    config.register(instance: requests)        // log every request, nested ones included
}

_ = try await mediator.send(PlaceOrder(...))
#expect(events.only(OrderPlaced.self) != nil)
#expect(requests.names == ["PlaceOrder", "GetPrice"])
```

`mock(_:with:)` is sugar for a protocol-keyed override; `mock(_:in: .mock, with:)` targets
an environment layer instead.

## Parallel safety

Swift Testing runs tests concurrently by default and nothing here opts out.

- The trait swaps the task-local root per test, so concurrent tests never share one.
- Discovery is scanned once per process and cached.
- Mutating ``SimpleResolver/processRoot`` from inside a test that does not use the trait
  races with every other test. In debug builds, once any test has used `.resolver`, such a
  mutation records a test issue naming the offending test. `ResolverTrait.installProcessRootGuard()`
  arms it unconditionally.
- Scope discovery to the test module with `.thisModule()`; see <doc:HowDiscoveryWorks>.

## Testing a handler directly

Construct it with a resolver and call `handle`. Use the mediator only in tests that are
about the pipeline.

```swift
let resolver = SimpleResolver()
resolver.register(Catalog.self, instance: FakeCatalog())
let handler = try GetPriceHandler(resolver: resolver)
#expect(try await handler.handle(GetPrice(sku: "TEA")) == 1_290)
```

## Factory users

Keep using `FactoryTesting`'s `.container` trait. Handlers created inside `send` resolve
their `@Injected` properties from the task-local container, so overrides reach them with no
mediator-specific setup.
