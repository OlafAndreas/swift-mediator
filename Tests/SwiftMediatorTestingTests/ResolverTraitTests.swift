import Testing
import SwiftMediator
import SwiftMediatorTesting

// MARK: Fixtures

struct NetworkClient: Sendable { let id = UUID() }
struct OrderAPI: Sendable { let client: NetworkClient; let label: String }

struct PlaceOrder: Request { typealias Response = String; let sku: String }
struct GetPrice: Request { typealias Response = Int; let sku: String }
struct OrderPlaced: Event { let sku: String; let price: Int }
struct Unrelated: Event {}

/// Uses the mediator to ask a nested question; tests stub `GetPrice`.
@Handler
struct PlaceOrderHandler: RequestHandler {
    let api: OrderAPI
    let mediator: Mediator
    func handle(_ request: PlaceOrder) async throws -> String {
        let price = try await mediator.send(GetPrice(sku: request.sku))
        try await mediator.publish(OrderPlaced(sku: request.sku, price: price))
        return "\(api.label): \(request.sku) @ \(price)"
    }
}

@Handler
struct GetPriceHandler: RequestHandler {
    func handle(_ request: GetPrice) async throws -> Int { 999 }   // the "real" one
}

struct AppModule: ResolverModule {
    func register(into resolver: SimpleResolver) {
        resolver.register(NetworkClient.self, lifetime: .singleton) { _ in NetworkClient() }
        resolver.register(OrderAPI.self, lifetime: .singleton) { r in OrderAPI(client: try r(), label: "prod") }
    }
}

// MARK: Tests

@Suite(.resolver) struct FreshRootTests {

    @Test func eachTestGetsAnEmptyRoot() throws {
        #expect(throws: ResolverError.self) { try SimpleResolver.shared.resolve(OrderAPI.self) }
    }

    @Test func mediatorDefaultsToTheTestRoot() async throws {
        SimpleResolver.shared.register(OrderAPI.self, instance: OrderAPI(client: NetworkClient(), label: "test"))
        let mediator = try Mediator(discovery: .thisModule())

        let result = try await mediator.send(PlaceOrder(sku: "TEA"))
        #expect(result == "test: TEA @ 999")
    }

    @Test func stubReplacesADiscoveredHandler() async throws {
        SimpleResolver.shared.register(OrderAPI.self, instance: OrderAPI(client: NetworkClient(), label: "test"))
        let mediator = try Mediator(discovery: .thisModule()) { config in
            config.stub(GetPrice.self) { _ in 42 }
        }

        #expect(try await mediator.send(PlaceOrder(sku: "TEA")) == "test: TEA @ 42")
        #expect(mediator.handlerType(for: GetPrice.self) == Mediator.Configuration.Stub<GetPrice>.self)
    }

    @Test func eventRecorderCapturesPublishedEvents() async throws {
        SimpleResolver.shared.register(OrderAPI.self, instance: OrderAPI(client: NetworkClient(), label: "test"))
        let events = EventRecorder()
        let mediator = try Mediator(discovery: .thisModule()) { config in
            config.stub(GetPrice.self) { _ in 7 }
            config.record(events)
        }

        _ = try await mediator.send(PlaceOrder(sku: "MUG"))
        try await mediator.publish(Unrelated())

        #expect(events.events.count == 2)
        #expect(events.only(OrderPlaced.self)?.price == 7)
        #expect(events.published(Unrelated.self).count == 1)
    }

    @Test func requestRecorderSeesEveryRequestIncludingNested() async throws {
        SimpleResolver.shared.register(OrderAPI.self, instance: OrderAPI(client: NetworkClient(), label: "test"))
        let requests = RequestRecorder()
        let mediator = try Mediator(discovery: .thisModule()) { config in
            config.stub(GetPrice.self) { _ in 1 }
            config.register(instance: requests)
        }

        _ = try await mediator.send(PlaceOrder(sku: "TEA"))

        #expect(requests.names == ["PlaceOrder", "GetPrice"])
        #expect(requests.sent(GetPrice.self).first?.sku == "TEA")
    }
}

/// The app's real wiring, installed once on the process-wide root, then inherited.
@Suite(.resolver(inheriting: true)) struct InheritedRootTests {

    init() {
        // Runs inside the suite's task-local root (isRecursive), so this seeds the copy
        // that each test will in turn copy from.
        SimpleResolver.shared.install(AppModule())
    }

    @Test func inheritsRegistrationsWithFreshSingletons() throws {
        let api: OrderAPI = try SimpleResolver.shared()
        #expect(api.label == "prod")
    }

    @Test func overridesOnlyWhatTheTestNeeds() async throws {
        SimpleResolver.shared.register(OrderAPI.self, instance: OrderAPI(client: NetworkClient(), label: "fake"))
        let mediator = try Mediator(discovery: .thisModule()) { $0.stub(GetPrice.self) { _ in 5 } }

        #expect(try await mediator.send(PlaceOrder(sku: "TEA")) == "fake: TEA @ 5")
    }
}

@Suite struct SeededTraitTests {
    @Test(.resolver { root in
        root.register(OrderAPI.self, instance: OrderAPI(client: NetworkClient(), label: "seeded"))
    })
    func traitCanSeedTheRoot() async throws {
        let mediator = try Mediator(discovery: .thisModule()) { $0.stub(GetPrice.self) { _ in 3 } }
        #expect(try await mediator.send(PlaceOrder(sku: "TEA")) == "seeded: TEA @ 3")
    }
}

import Foundation
