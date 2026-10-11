# Getting started

Add the package, define a request, write a handler, send.

## Add the package

```swift
// Package.swift
.package(url: "https://github.com/OlafAndreas/swift-mediator", from: "0.1.0")

// In a target
.product(name: "SwiftMediator", package: "swift-mediator")
```

The core has no runtime dependencies. Bindings for Factory, Vapor and Fluent live behind
package traits, so a consumer who does not enable them never fetches those packages:

```swift
.package(url: "https://github.com/OlafAndreas/swift-mediator", from: "0.1.0", traits: ["Vapor", "Fluent"])
```

Swift 6.2 or later is required for the `@section` and `@used` attributes the macro emits.

## Define a request

A request names its response type. A nested type called `Response` satisfies the
requirement without a typealias; a request that answers with an existing type writes one.

```swift
import SwiftMediator

struct PlaceOrder: Request {
    struct Response: Sendable { let orderID: String; let totalOre: Int }
    let customerEmail: String
    let lines: [OrderLine]
}

struct GetOrder: Request {
    typealias Response = Order?
    let id: String
}
```

## Write a handler

Mark it with ``Handler()``. Dependencies are stored properties; the macro generates the
initialiser that resolves them by type.

```swift
@Handler
struct PlaceOrderHandler: RequestHandler {
    let repository: OrderRepository
    let payments: PaymentGateway
    let mediator: Mediator                     // always available, for publishing events

    func handle(_ request: PlaceOrder) async throws -> PlaceOrder.Response {
        let order = Order(request)
        let txn = try payments.charge(order.totalOre)
        await repository.save(order)
        try await mediator.publish(OrderPlaced(order: order))
        return .init(orderID: order.id, totalOre: order.totalOre)
    }
}
```

## Register dependencies and send

Long-lived objects go on the shared root. Nothing names the handler.

```swift
SimpleResolver.shared.register(OrderRepository.self, lifetime: .singleton) { _ in OrderRepository() }
SimpleResolver.shared.register(PaymentGateway.self) { _ in PaymentGateway() }

let mediator = try Mediator()                  // scans the binary; throws on misconfiguration
let confirmation = try await mediator.send(PlaceOrder(customerEmail: "olaf@example.com", lines: lines))
```

## Where to go next

- <doc:PipelineBehaviors> for validation, logging, retries and transactions around every send.
- <doc:DependencyInjection> for lifetimes, modules and environments.
- <doc:Testing> for stubs, recorders and the per-test resolver trait.
- <doc:VaporIntegration> if this is a server.
