#if Fluent
import Fluent
import Vapor
@_exported import SwiftMediatorVapor

/// The database every component built inside a `FluentTransaction` should use.
public enum CurrentDatabase {
    /// Set by `FluentTransaction` around `next`. `nil` outside a transaction.
    @TaskLocal public static var transaction: (any Database)?
}

/// Wraps `Transactional` requests in `req.db.transaction { }`. Everything inside, the
/// handler and inner behaviors included, is constructed within the transaction, so a
/// `let db: any Database` property resolves to the transaction's connection. Throwing
/// anywhere inside rolls back; returning commits. Non-transactional requests pass through.
///
/// Order -50: inside validation (no transaction for a rejected request), outside logging
/// and retries, so a retry gets a fresh transaction per attempt.
public struct FluentTransaction: PipelineBehavior {
    public static var order: Int { -50 }

    let request: Vapor.Request

    public init(resolver: any Resolver) throws {
        request = try resolver()
    }

    public func handle<R: SwiftMediator.Request>(_ message: R, next: Next<R>) async throws -> R.Response {
        guard message is any Transactional else { return try await next(message) }
        // `transaction` takes an escaping closure; `next` is non-escaping but never outlives this call.
        return try await withoutActuallyEscaping(next) { next in
            try await request.db.transaction { db in
                try await CurrentDatabase.$transaction.withValue(db) { try await next(message) }
            }
        }
    }
}

public extension Application {
    /// Registers the transaction behavior and seeds every request scope with
    /// `any Database`: the transaction's database inside a `FluentTransaction`, otherwise
    /// `req.db`. Handlers declare `let db: any Database` and need not know which.
    func useFluentTransactions() {
        configureMediator { $0.register(FluentTransaction.self) }
        seedRequests { req, scope in
            scope.register((any Database).self) { _ in CurrentDatabase.transaction ?? req.db }
        }
    }
}
#endif
