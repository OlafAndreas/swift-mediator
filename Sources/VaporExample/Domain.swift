// Domain code imports the core only. No Vapor here, so `Request` is unambiguous.
import SwiftMediator
import Foundation

struct Order: Codable, Sendable {
    let id: UUID
    let customerEmail: String
    let totalOre: Int
}

// MARK: Messages

struct PlaceOrder: Request, Codable {
    struct Response: Codable, Sendable { let id: UUID; let totalOre: Int }
    let customerEmail: String
    let amountOre: Int
}

struct GetOrder: Request {
    typealias Response = Order?
    let id: UUID
}

struct OrderPlaced: Event { let order: Order }

// MARK: Infrastructure

actor OrderStore {
    private var orders: [UUID: Order] = [:]
    func save(_ order: Order) { orders[order.id] = order }
    func find(_ id: UUID) -> Order? { orders[id] }
}

/// Exists per request. Seeded from the Vapor request in `configure`.
struct RequestInfo: Sendable {
    let id: String
    let path: String
}

// MARK: Handlers

@Handler
struct PlaceOrderHandler: RequestHandler {
    let store: OrderStore          // singleton from app.resolver
    let info: RequestInfo          // seeded per request
    let mediator: Mediator

    func handle(_ request: PlaceOrder) async throws -> PlaceOrder.Response {
        let order = Order(id: UUID(), customerEmail: request.customerEmail, totalOre: request.amountOre)
        await store.save(order)
        try await mediator.publish(OrderPlaced(order: order))
        return .init(id: order.id, totalOre: order.totalOre)
    }
}

@Handler
struct GetOrderHandler: RequestHandler {
    let store: OrderStore
    func handle(_ request: GetOrder) async throws -> Order? { await store.find(request.id) }
}
