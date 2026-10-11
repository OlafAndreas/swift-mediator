import SwiftMediatorFactory   // re-exports FactoryKit and SwiftMediator
import Foundation

// MARK: - Domain

struct OrderLine: Sendable {
    let sku: String
    let quantity: Int
    let unitPriceOre: Int          // integer øre, no floating point
}

struct Order: Sendable {
    let id: String
    let customerEmail: String
    let lines: [OrderLine]
    var totalOre: Int { lines.reduce(0) { $0 + $1.quantity * $1.unitPriceOre } }
}

enum OrderError: Error { case paymentDeclined(reason: String) }

/// Errors a `Retry` behavior may retry. Permanent failures (declined card, validation)
/// must not conform.
protocol TransientError: Error {}
enum GatewayError: TransientError { case unavailable }

/// Thrown by `Retry` when every attempt failed transiently. Non-transient errors and
/// successes pass through untouched, so only this path looks different to the caller.
struct RetryExhausted: Error, CustomStringConvertible {
    let attempts: Int
    let last: any Error
    var description: String { "gave up after \(attempts) attempts; last error: \(last)" }
}
struct ValidationError: Error, CustomStringConvertible {
    let problems: [String]
    var description: String { "Validation failed: " + problems.joined(separator: "; ") }
}

// MARK: - Infrastructure (what the DI container provides)

actor OrderRepository {
    private var orders: [String: Order] = [:]
    func save(_ order: Order) { orders[order.id] = order }
    func find(_ id: String) -> Order? { orders[id] }
}

actor Inventory {
    private var stock = ["SKU-TEA": 10, "SKU-MUG": 3]
    func reserve(_ sku: String, _ quantity: Int) throws {
        guard let have = stock[sku], have >= quantity else { throw InventoryError.outOfStock(sku) }
        stock[sku] = have - quantity
    }
    enum InventoryError: Error { case outOfStock(String) }
}

/// Simulated outage: the gateway fails `remaining` times with a transient error, then recovers.
final class Outages: @unchecked Sendable {
    private var remaining = 0
    private let lock = NSLock()
    func schedule(_ count: Int) { lock.withLock { remaining = count } }
    func consume() -> Bool { lock.withLock { guard remaining > 0 else { return false }; remaining -= 1; return true } }
}

struct PaymentGateway: Sendable {
    let outages: Outages
    func charge(_ amountOre: Int, to email: String) throws -> String {
        if outages.consume() { throw GatewayError.unavailable }                       // transient
        guard amountOre < 100_000 else { throw OrderError.paymentDeclined(reason: "limit exceeded") }   // permanent
        return "txn_\(email.prefix(3))_\(amountOre)"
    }
}

struct Mailer: Sendable {
    func send(to: String, subject: String) { print("   📧 \(to): \(subject)") }
}

// MARK: - Factory registrations (the only wiring in the app)

extension Container {
    var orderRepository: Factory<OrderRepository> { self { OrderRepository() }.singleton }
    var inventory: Factory<Inventory>             { self { Inventory() }.singleton }
    var outages: Factory<Outages>                 { self { Outages() }.singleton }
    var paymentGateway: Factory<PaymentGateway>   { self { PaymentGateway(outages: self.outages()) } }
    var mailer: Factory<Mailer>                   { self { Mailer() } }
}

// MARK: - Cross-cutting: a request opts into validation by conforming to this

protocol Validatable {
    func validate() -> [String]
}

/// A request opts into retries by conforming. Only safe for requests whose handler has no
/// side effects before the point that can fail transiently, or is idempotent.
protocol Retryable {
    var maxAttempts: Int { get }
}
extension Retryable { var maxAttempts: Int { 3 } }

// MARK: - Messages

struct PlaceOrder: Request, Validatable, Retryable {
    /// A nested type named `Response` satisfies the associated type; no typealias needed.
    struct Response: Sendable { let orderID: String; let transactionID: String; let totalOre: Int }

    let customerEmail: String
    let lines: [OrderLine]

    func validate() -> [String] {
        var problems: [String] = []
        if !customerEmail.contains("@") { problems.append("invalid email") }
        if lines.isEmpty { problems.append("order has no lines") }
        if lines.contains(where: { $0.quantity <= 0 }) { problems.append("quantity must be positive") }
        return problems
    }
}

struct GetOrder: Request {
    typealias Response = Order?
    let id: String
}

protocol OrderEvent: Event { var orderID: String { get } }
struct OrderPlaced: OrderEvent { let orderID: String; let order: Order }
struct PaymentFailed: OrderEvent { let orderID: String; let reason: String }

// MARK: - Request handlers

@Handler
struct PlaceOrderHandler: RequestHandler {
    @Injected(\.orderRepository) private var repository
    @Injected(\.paymentGateway) private var payments
    @Injected(\.mediator) private var mediator     // handlers can publish events through the mediator

    func handle(_ request: PlaceOrder) async throws -> PlaceOrder.Response {
        let order = Order(id: "ord_\(Int.random(in: 1000...9999))",
                          customerEmail: request.customerEmail,
                          lines: request.lines)

        let transactionID: String
        do {
            transactionID = try payments.charge(order.totalOre, to: order.customerEmail)
        } catch OrderError.paymentDeclined(let reason) {
            try await mediator.publish(PaymentFailed(orderID: order.id, reason: reason))
            throw OrderError.paymentDeclined(reason: reason)
        }

        await repository.save(order)
        try await mediator.publish(OrderPlaced(orderID: order.id, order: order))
        return .init(orderID: order.id, transactionID: transactionID, totalOre: order.totalOre)
    }
}

@Handler
struct GetOrderHandler: RequestHandler {
    @Injected(\.orderRepository) private var repository
    func handle(_ request: GetOrder) async throws -> Order? {
        await repository.find(request.id)
    }
}

// MARK: - Event handlers (fan-out)

@Handler
struct ReserveInventory: EventHandler {
    @Injected(\.inventory) private var inventory
    func handle(_ event: OrderPlaced) async throws {
        for line in event.order.lines { try await inventory.reserve(line.sku, line.quantity) }
        print("   📦 reserved stock for \(event.orderID)")
    }
}

@Handler
struct SendOrderConfirmation: EventHandler {
    @Injected(\.mailer) private var mailer
    func handle(_ event: OrderPlaced) async throws {
        mailer.send(to: event.order.customerEmail, subject: "Order \(event.orderID) confirmed")
    }
}

@Handler
struct NotifyPaymentFailure: EventHandler {
    @Injected(\.mailer) private var mailer
    func handle(_ event: PaymentFailed) async throws {
        mailer.send(to: "ops@shop.example", subject: "Payment failed for \(event.orderID): \(event.reason)")
    }
}

/// Covariant subscription: receives every `OrderEvent`, whatever the concrete type.
@Handler
struct AuditTrail: EventHandler {
    func handle(_ event: any OrderEvent) async throws {
        print("   🧾 audit: \(type(of: event)) \(event.orderID)")
    }
}

// MARK: - Pipeline behaviors

@Behavior
struct Validation: PipelineBehavior {
    static var order: Int { -100 }     // outermost: reject before anything else runs

    func handle<R: Request>(_ request: R, next: Next<R>) async throws -> R.Response {
        if let validatable = request as? any Validatable {
            let problems = validatable.validate()
            if !problems.isEmpty { throw ValidationError(problems: problems) }
        }
        return try await next(request)
    }
}

@Behavior
struct Logging: PipelineBehavior {
    func handle<R: Request>(_ request: R, next: Next<R>) async throws -> R.Response {
        print("→ \(R.self)")
        do {
            let response = try await next(request)
            print("← \(R.self) ok")
            return response
        } catch {
            print("← \(R.self) failed: \(error)")
            throw error
        }
    }
}

/// Calls `next` again on a transient error, up to `maxAttempts`. Sits inside Logging so one
/// log line covers all attempts, and outside Timing so each attempt is timed on its own.
/// Everything inside it, the handler included, runs once per attempt.
@Behavior
struct Retry: PipelineBehavior {
    static var order: Int { 50 }

    func handle<R: Request>(_ request: R, next: Next<R>) async throws -> R.Response {
        guard let retryable = request as? any Retryable else { return try await next(request) }
        var attempt = 1
        while true {
            do {
                return try await next(request)
            } catch let error as any TransientError {
                guard attempt < retryable.maxAttempts else {
                    throw RetryExhausted(attempts: attempt, last: error)   // callers can tell retries happened
                }
                print("   ↻ attempt \(attempt) failed (\(error)), retrying")
                attempt += 1
                try await Task.sleep(for: .milliseconds(20 * attempt))   // linear backoff
            }
        }
    }
}

@Behavior
struct Timing: PipelineBehavior {
    static var order: Int { 100 }      // innermost: measures only the handler

    func handle<R: Request>(_ request: R, next: Next<R>) async throws -> R.Response {
        let start = ContinuousClock.now
        defer { print("   ⏱ \(R.self) took \(ContinuousClock.now - start)") }
        return try await next(request)
    }
}

// MARK: - Composition root

let mediator = Container.shared.mediator()      // singleton; discovery runs here

print("pipeline:", mediator.behaviorTypes.map { "\($0)" }.joined(separator: " → "))
print()

// MARK: - Scenarios

func run(_ title: String, _ body: () async throws -> Void) async {
    print("## \(title)")
    do { try await body() } catch { print("   ✗ \(error)") }
    print()
}

await run("Happy path") {
    let confirmation = try await mediator.send(PlaceOrder(
        customerEmail: "olaf@example.com",
        lines: [OrderLine(sku: "SKU-TEA", quantity: 2, unitPriceOre: 12_900),
                OrderLine(sku: "SKU-MUG", quantity: 1, unitPriceOre: 19_900)]
    ))
    print("   ✓ \(confirmation.orderID) paid \(confirmation.totalOre) øre via \(confirmation.transactionID)")

    let stored = try await mediator.send(GetOrder(id: confirmation.orderID))
    print("   ✓ stored order has \(stored?.lines.count ?? 0) lines")
}

await run("Validation rejects before the handler runs") {
    _ = try await mediator.send(PlaceOrder(customerEmail: "not-an-email", lines: []))
}

await run("Payment declined publishes PaymentFailed") {
    _ = try await mediator.send(PlaceOrder(
        customerEmail: "big@spender.example",
        lines: [OrderLine(sku: "SKU-TEA", quantity: 100, unitPriceOre: 12_900)]
    ))
}

await run("Transient gateway outage is retried") {
    Container.shared.outages().schedule(2)            // fail twice, succeed on the third attempt
    let confirmation = try await mediator.send(PlaceOrder(
        customerEmail: "olaf@example.com",
        lines: [OrderLine(sku: "SKU-TEA", quantity: 1, unitPriceOre: 12_900)]
    ))
    print("   ✓ \(confirmation.orderID) succeeded after retries")
}

await run("Outage that outlasts the retry budget fails") {
    Container.shared.outages().schedule(5)
    _ = try await mediator.send(PlaceOrder(
        customerEmail: "olaf@example.com",
        lines: [OrderLine(sku: "SKU-TEA", quantity: 1, unitPriceOre: 12_900)]
    ))
}

await run("Unknown order returns nil") {
    let missing = try await mediator.send(GetOrder(id: "ord_0000"))
    print("   ✓ found: \(missing == nil ? "nil" : "order")")
}
