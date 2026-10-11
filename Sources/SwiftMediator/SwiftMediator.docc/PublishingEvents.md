# Publishing events

One-to-many dispatch with no return value.

## Semantics

`publish` walks every registered ``EventHandler`` in registration order and runs each whose
`Note` type matches the event. Matching is a runtime `is` check:

- A handler for `UserCreated` fires for that struct only.
- A handler for `any UserEvent` fires for every conforming event.
- A handler for `any Event` sees everything, which suits audit and recording.

Handlers run sequentially inside one resolver scope. The first error stops the sequence and
is rethrown to the publisher. Zero matching handlers is not an error, and costs almost
nothing: the mediator returns before opening a scope.

## Publishing from a handler

Inject ``Mediator`` and publish. The injected mediator is bound to the current scope, so
event handlers share the sending handler's scoped instances, such as a unit of work or a
transaction.

```swift
@Handler
struct PlaceOrderHandler: RequestHandler {
    let mediator: Mediator
    func handle(_ request: PlaceOrder) async throws -> PlaceOrder.Response {
        ...
        try await mediator.publish(OrderPlaced(order: order))
        ...
    }
}
```

## Pitfalls

- Do not rely on ordering between event handlers. Registration order under discovery is
  qualified-name order, which is stable but meaningless. If B must follow A, have A publish
  a second event, or merge them.
- A failing event handler fails the `send` that published. For side effects that must not
  break the main flow, catch inside the handler or run them detached.
- Events are not commands. If the caller needs the work to happen, it is a request.

## Observing all events

``Mediator/Configuration/onEvent(_:)`` registers a closure that sees every published
event. The testing product's `EventRecorder` is built on it.
