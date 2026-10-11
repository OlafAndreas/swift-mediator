# Scopes and lifetimes

What happens to instances during one `send`.

## One scope per call

Every `send` and `publish` opens one resolver scope through ``Resolver/withScope(_:)``.
The handler and all behaviors are resolved through that scope, so anything registered as
`.scoped` is shared by them for the duration of the call and released afterwards. That is
the per-request lifetime MediatR users get from a scoped DI container.

```swift
struct RequestContext: Sendable { let correlationID = UUID().uuidString }
SimpleResolver.shared.register(RequestContext.self, lifetime: .scoped) { _ in RequestContext() }

@Behavior
struct Logging: PipelineBehavior {
    let context: RequestContext            // same instance as the handler below
    ...
}

@Handler
struct PlaceOrderHandler: RequestHandler {
    let context: RequestContext
    let mediator: Mediator                 // bound to this scope
    ...
}
```

## Nested calls

The ``Mediator`` injected into a handler is bound to the current scope. A `send` or
`publish` made through it reuses the outer scope, so scoped instances are shared with the
inner call. Calling a root mediator instance you obtained elsewhere opens a fresh scope
instead. Nested scopes are not a concept here; there is the current scope or a new one.

## Singletons and children

A singleton is cached on the resolver that owns its registration. A per-request child or an
environment layer resolving it gets the same instance. An override registered on the child
is the child's own. To get fresh instances, ``SimpleResolver/copy()`` flattens a chain into
a standalone resolver with no cached singletons; the test trait uses it.

Singletons are built by their owner, never through a child or a scope, so a singleton cannot
capture scoped state. A `.singleton` service whose factory resolves a `.scoped` value throws
rather than freezing the first request's instance forever.

## Construction order

Components are constructed just in time, inside the behaviors that wrap them. See
<doc:PipelineBehaviors> for why that matters.

## Your own resolver

Implement ``Resolver/withScope(_:)`` to participate in scoping. The default passes `self`
through, which is correct for a resolver without lifetimes.
