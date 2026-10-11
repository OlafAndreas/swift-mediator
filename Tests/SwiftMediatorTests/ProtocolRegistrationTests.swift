import Testing
import SwiftMediator

protocol OrderStore: Sendable {
    func name() -> String
}
struct RemoteOrderStore: OrderStore { func name() -> String { "remote" } }
struct InMemoryOrderStore: OrderStore { func name() -> String { "memory" } }

protocol TimeSource: Sendable { var now: String { get } }
struct FixedTime: TimeSource { let now = "12:00" }

struct WhichStore: Request { typealias Response = String }

/// Handler depends on protocols only. The macro generates
/// `self.store = try resolver.resolve((any OrderStore).self)` and the same for TimeSource.
@Handler
struct WhichStoreHandler: RequestHandler {
    let store: any OrderStore
    let clock: any TimeSource
    func handle(_ request: WhichStore) async throws -> String { "\(store.name()) @ \(clock.now)" }
}

@Suite struct ProtocolRegistrationTests {

    @Test func registerAnImplementationUnderItsProtocol() async throws {
        let resolver = SimpleResolver()
        resolver.register((any OrderStore).self, lifetime: .singleton) { _ in RemoteOrderStore() }
        resolver.register((any TimeSource).self, instance: FixedTime())        // instance also works

        let mediator = try Mediator(resolver: resolver, discovery: false) { $0.register(WhichStoreHandler.self) }
        #expect(try await mediator.send(WhichStore()) == "remote @ 12:00")
    }

    @Test func swapTheImplementationWithoutTouchingTheHandler() async throws {
        let resolver = SimpleResolver()
        resolver.register((any OrderStore).self) { _ in InMemoryOrderStore() }
        resolver.register((any TimeSource).self, instance: FixedTime())

        let mediator = try Mediator(resolver: resolver, discovery: false) { $0.register(WhichStoreHandler.self) }
        #expect(try await mediator.send(WhichStore()) == "memory @ 12:00")
    }

    @Test func protocolAndConcreteKeysAreDistinct() throws {
        let resolver = SimpleResolver()
        resolver.register((any OrderStore).self) { _ in RemoteOrderStore() }

        let viaProtocol: any OrderStore = try resolver()
        #expect(viaProtocol.name() == "remote")
        #expect(throws: ResolverError.self) { try resolver.resolve(RemoteOrderStore.self) }
    }

    @Test func bareProtocolNameIsTheSameKeyAsAnyForm() throws {
        let resolver = SimpleResolver()
        resolver.register(OrderStore.self) { _ in RemoteOrderStore() }          // without `any`
        #expect(try resolver.resolve((any OrderStore).self).name() == "remote")
    }
}
