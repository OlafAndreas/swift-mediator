# Environments

Named registration layers that fall back to the root.

## Overview

``SimpleResolver/environment(_:)`` returns a child resolver named by a
``ResolverEnvironment``, created on first use and reused afterwards. It answers from its own
registrations first and falls back to the resolver it was created from. Registering there
never changes the root.

```swift
let root = SimpleResolver.processRoot
root.register(PaymentGateway.self, lifetime: .singleton) { _ in StripeGateway() }
root.register(PaymentGateway.self, in: .mock, instance: FakeGateway())   // root unchanged

try root.resolve(PaymentGateway.self)                    // Stripe
try root.environment(.mock).resolve(PaymentGateway.self) // Fake
try root.environment(.mock).resolve(Mailer.self)         // falls back to root
```

`.mock` and `.preview` are predefined. Any string literal is a valid name, and layers nest:
`root.environment(.mock).environment("offline")`.

## Switching for a task

``SimpleResolver/using(_:_:)`` points the task-local shared root at a layer for the
duration of a task. Only lookups inside want the mock; everything else is unchanged.

```swift
try await SimpleResolver.using(.mock) {
    let mediator = try Mediator()          // resolves through the mock layer
    ...
}
```

A mediator can also be built directly on a layer: `Mediator(resolver: root.environment(.mock))`.

## Instances

A singleton belongs to the resolver it is registered on. A layer resolving a root singleton
gets the root's instance; an override registered on the layer is the layer's own. For fresh
instances use ``SimpleResolver/copy()``, which flattens a chain into a standalone resolver.
The test trait's `.resolver(environment: .mock)` is exactly that copy.
