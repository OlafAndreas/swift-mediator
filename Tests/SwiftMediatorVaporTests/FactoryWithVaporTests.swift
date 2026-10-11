#if Vapor && Factory
import Testing
import Vapor
import VaporTesting
import SwiftMediatorVapor
import SwiftMediatorFactory   // FactoryKit

/// App-wide service registered with Factory.
struct Pricing: Sendable { let unitOre: Int }
extension Container {
    var pricing: Factory<Pricing> { self { Pricing(unitOre: 1_200) }.singleton }
}

struct Quote: SwiftMediator.Request, Content {
    struct Response: Content { let totalOre: Int; let requestID: String }
    let quantity: Int
}

/// Mixes the two styles: Factory for the app-wide service, a seeded stored property for
/// the per-request value. The macro skips the wrapped property and resolves the other.
@Handler
struct QuoteHandler: RequestHandler {
    @Injected(\.pricing) private var pricing
    let request: Vapor.Request

    func handle(_ quote: Quote) async throws -> Quote.Response {
        .init(totalOre: pricing.unitOre * quote.quantity, requestID: request.id)
    }
}

@Suite struct FactoryWithVaporTests {

    @Test func factoryServicesAndRequestValuesInOneHandler() async throws {
        let app = try await Application.make(.testing)
        app.resolver = SimpleResolver()
        app.post("quote") { req in try await req.send(Quote.self) }

        do {
            try await app.testing().test(.POST, "quote", beforeRequest: { try $0.content.encode(Quote(quantity: 3)) }) { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(Quote.Response.self)
                #expect(body.totalOre == 3_600)
                #expect(!body.requestID.isEmpty)
            }
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
#endif
