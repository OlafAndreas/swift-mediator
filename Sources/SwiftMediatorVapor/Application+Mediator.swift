#if Vapor
import Vapor
@_exported import SwiftMediator

/// Adds request-time values to the resolver a request's handlers see. Register your
/// Fluent database, the authenticated user, a request ID, or anything else that exists
/// only once a request is in flight.
public typealias RequestSeed = @Sendable (Vapor.Request, SimpleResolver) -> Void

public extension Application {
    private struct ResolverKey: StorageKey { typealias Value = SimpleResolver }
    private struct MediatorKey: StorageKey { typealias Value = Mediator }
    private struct SeedsKey: StorageKey { typealias Value = [RequestSeed] }

    /// The app's composition root. Defaults to `SimpleResolver.processRoot`. Set it in
    /// `configure` before the first request if you want a dedicated root.
    var resolver: SimpleResolver {
        get { storage[ResolverKey.self] ?? .processRoot }
        set { storage[ResolverKey.self] = newValue }
    }

    /// The app-wide mediator. Built on first access from `resolver` with discovery on.
    /// A configuration error terminates the process with the message, the same fail-fast
    /// rule as everywhere else. Assign your own to override, for example with stubs.
    var mediator: Mediator {
        get {
            if let existing = storage[MediatorKey.self] { return existing }
            do {
                let mediator = try Mediator(resolver: resolver)
                storage[MediatorKey.self] = mediator
                return mediator
            } catch {
                fatalError("SwiftMediator configuration error: \(error)")
            }
        }
        set { storage[MediatorKey.self] = newValue }
    }

    var requestSeeds: [RequestSeed] {
        get { storage[SeedsKey.self] ?? [] }
        set { storage[SeedsKey.self] = newValue }
    }

    /// Registers a seed that runs for every request's resolver.
    ///
    ///     app.seedRequests { req, scope in
    ///         scope.register(Database.self, instance: req.db)
    ///     }
    func seedRequests(_ seed: @escaping RequestSeed) {
        requestSeeds.append(seed)
    }
}
#endif
