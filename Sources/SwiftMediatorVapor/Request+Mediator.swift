#if Vapor
import Vapor
import SwiftMediator

public extension Vapor.Request {
    /// The app's mediator bound to a resolver that knows about this request.
    ///
    /// The resolver is a child of `app.resolver`, pre-seeded with the `Request` itself and
    /// its `Logger`, plus whatever `app.seedRequests` added. Handlers declare those as plain
    /// stored properties. Each access builds a fresh child, so read it once per route.
    var mediator: Mediator {
        let scope = SimpleResolver(parent: application.resolver)
        scope.register(Vapor.Request.self) { _ in self }
        scope.register(Logger.self, instance: logger)
        for seed in application.requestSeeds { seed(self, scope) }
        return application.mediator.bound(to: scope)
    }

    /// Decodes `R` from the body and sends it. `R` must be `Content`.
    func send<R: SwiftMediator.Request & Content>(_ type: R.Type) async throws -> R.Response {
        try await mediator.send(try content.decode(R.self))
    }

    /// Decodes `R` from the query string and sends it.
    func sendQuery<R: SwiftMediator.Request & Content>(_ type: R.Type) async throws -> R.Response {
        try await mediator.send(try query.decode(R.self))
    }
}

/// Lets a request's `Response` type be returned straight from a route when it is `Content`.
public extension SwiftMediator.Request where Response: Content {
    typealias RouteResponse = Response
}
#endif
