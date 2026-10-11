# Requests and events

The two kinds of message, and how they differ.

## Requests

A ``Request`` has exactly one handler and produces a `Response`. `send` returns it. Two
handlers for one request type fail at the ``Mediator`` initialiser.

```swift
struct GetPrice: Request {
    typealias Response = Int
    let sku: String
}
```

Requests and responses must be `Sendable`, since they cross into the mediator's scope.
Prefer a nested `struct Response` when the request owns its result type; it reads well at
the call site as `PlaceOrder.Response` and needs no typealias.

Marker protocols on a request let behaviors opt it into cross-cutting treatment at runtime:

```swift
struct PlaceOrder: Request, Validatable, Retryable, Transactional { ... }
```

``Transactional`` is provided by the core for integrations to act on. The others are
yours to define; see <doc:PipelineBehaviors>.

## Events

An ``Event`` is broadcast to zero or more handlers and returns nothing. `publish` runs each
matching handler in registration order. Publishing an event nobody listens to is not an
error.

```swift
protocol OrderEvent: Event { var orderID: String { get } }
struct OrderPlaced: OrderEvent { let orderID: String; let order: Order }
struct PaymentFailed: OrderEvent { let orderID: String; let reason: String }
```

Sharing a protocol between events lets one handler subscribe to all of them; see
<doc:PublishingEvents>.

## Which one to use

| | `send` | `publish` |
|---|---|---|
| Handlers | exactly one | zero or more |
| Return value | the handler's `Response` | none |
| Pipeline behaviors | wrap the handler | not applied |
| Matching | exact request type | `is` check, so protocols and class hierarchies match |

If the caller needs the thing to happen, it is a request. If the caller is announcing that
something happened and does not care who listens, it is an event.
