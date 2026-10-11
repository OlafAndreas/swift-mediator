import Testing
import SwiftMediator

protocol Gateway: Sendable { var name: String { get } }
struct RealGateway: Gateway { let name = "real" }
struct FakeGateway: Gateway { let name = "fake" }
struct Mailer: Sendable { let id: Int }

@Suite struct EnvironmentTests {

    func makeRoot() -> SimpleResolver {
        let root = SimpleResolver()
        root.register((any Gateway).self, lifetime: .singleton) { _ in RealGateway() }
        root.register(Mailer.self, lifetime: .singleton) { _ in Mailer(id: Int.random(in: 1...1_000_000)) }
        return root
    }

    @Test func mockLayerOverridesWithoutTouchingTheDefault() throws {
        let root = makeRoot()
        root.register((any Gateway).self, in: .mock, instance: FakeGateway())

        #expect(try root.resolve((any Gateway).self).name == "real")
        #expect(try root.environment(.mock).resolve((any Gateway).self).name == "fake")
    }

    @Test func mockLayerFallsBackToTheDefaultForEverythingElse() throws {
        let root = makeRoot()
        let mock = root.environment(.mock)
        mock.register((any Gateway).self, instance: FakeGateway())

        #expect(throws: Never.self) { try mock.resolve(Mailer.self) }     // only registered on root
    }

    @Test func lookupOnlyUsesTheMockWhenAskedTo() async throws {
        let root = makeRoot()
        root.register((any Gateway).self, in: .mock, instance: FakeGateway())

        try await SimpleResolver.$shared.withValue(root) {
            let viaDefault: any Gateway = try SimpleResolver.shared()
            #expect(viaDefault.name == "real")

            let viaMock = try await SimpleResolver.using(.mock) {
                let gateway: any Gateway = try SimpleResolver.shared()
                return gateway.name
            }
            #expect(viaMock == "fake")

            let afterwards: any Gateway = try SimpleResolver.shared()
            #expect(afterwards.name == "real")
        }
    }

    @Test func environmentLayersAreReusedByName() {
        let root = makeRoot()
        #expect(root.environment(.mock) === root.environment(.mock))
        #expect(root.environment(.mock) !== root.environment(.preview))
        #expect(root.environment("mock") === root.environment(.mock))
    }

    @Test func layersOwnTheirInstances() throws {
        let root = makeRoot()
        let mock = root.environment(.mock)

        let rootMailer = try root.resolve(Mailer.self)
        let mockMailer = try mock.resolve(Mailer.self)
        #expect(rootMailer.id != mockMailer.id, "singleton resolved through a layer is that layer's instance")
        #expect(try mock.resolve(Mailer.self).id == mockMailer.id, "and is cached there")
        #expect(try root.resolve(Mailer.self).id == rootMailer.id, "root keeps its own")
    }

    @Test func mediatorCanBeBuiltOnALayer() async throws {
        struct WhichGateway: Request { typealias Response = String }
        struct WhichGatewayHandler: RequestHandler {
            let gateway: any Gateway
            init(resolver: any Resolver) throws { gateway = try resolver() }
            func handle(_ request: WhichGateway) async throws -> String { gateway.name }
        }

        let root = makeRoot()
        root.register((any Gateway).self, in: .mock, instance: FakeGateway())

        let live = try Mediator(resolver: root, discovery: false) { $0.register(WhichGatewayHandler.self) }
        let mocked = try Mediator(resolver: root.environment(.mock), discovery: false) { $0.register(WhichGatewayHandler.self) }

        #expect(try await live.send(WhichGateway()) == "real")
        #expect(try await mocked.send(WhichGateway()) == "fake")
    }

    @Test func layersCompose() throws {
        let root = makeRoot()
        let mock = root.environment(.mock)
        let offline = mock.environment("offline")
        offline.register(Mailer.self, instance: Mailer(id: -1))

        #expect(try offline.resolve(Mailer.self).id == -1)
        #expect(try offline.resolve((any Gateway).self).name == "real")   // two levels up
        #expect(try mock.resolve(Mailer.self).id != -1)
    }
}
