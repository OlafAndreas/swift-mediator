#if Vapor
import Vapor
import SwiftMediatorVapor   // re-exports SwiftMediator

// MARK: Vapor-facing glue lives here, where `Request` means Vapor's.

extension PlaceOrder: Content {}
extension PlaceOrder.Response: Content {}
extension Order: Content {}

/// Request-scoped logging through the mediator pipeline: the Logger comes from the request.
@Behavior
struct RequestLogging: PipelineBehavior {
    let logger: Logger
    let info: RequestInfo

    func handle<R: SwiftMediator.Request>(_ request: R, next: Next<R>) async throws -> R.Response {
        logger.info("→ \(R.self)", metadata: ["request-id": .string(info.id), "path": .string(info.path)])
        let response = try await next(request)
        logger.info("← \(R.self)")
        return response
    }
}

@Handler
struct LogOrderPlaced: EventHandler {
    let logger: Logger
    func handle(_ event: OrderPlaced) async throws {
        logger.notice("order placed", metadata: ["id": .string(event.order.id.uuidString)])
    }
}

func configure(_ app: Application) throws {
    // Composition root: long-lived things.
    app.resolver.register(OrderStore.self, lifetime: .singleton) { _ in OrderStore() }

    // Per-request things.
    app.seedRequests { req, scope in
        scope.register(RequestInfo.self, instance: RequestInfo(id: req.id, path: req.url.path))
    }

    // Routes are one line each.
    app.post("orders") { req in try await req.send(PlaceOrder.self) }
    app.get("orders", ":id") { req -> Order in
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        guard let order = try await req.mediator.send(GetOrder(id: id)) else { throw Abort(.notFound) }
        return order
    }
}

var env = try Environment.detect()
try LoggingSystem.bootstrap(from: &env)
let app = try await Application.make(env)
do {
    try configure(app)
    try await app.execute()
} catch {
    try? await app.asyncShutdown()
    throw error
}
try await app.asyncShutdown()
#else
print("VaporExample needs the Vapor trait: swift run --traits Vapor VaporExample")
#endif
