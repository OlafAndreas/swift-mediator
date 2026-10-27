#if Fluent
import Testing
import Vapor
import Fluent
import FluentSQLiteDriver
import VaporTesting
import SwiftMediatorFluent

// MARK: Schema

final class Ledger: Model, @unchecked Sendable {
    static let schema = "ledger"
    @ID(key: .id) var id: UUID?
    @Field(key: "amount") var amount: Int
    init() {}
    init(amount: Int) { self.amount = amount }
}

struct CreateLedger: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("ledger").id().field("amount", .int, .required).create()
    }
    func revert(on database: any Database) async throws { try await database.schema("ledger").delete() }
}

// MARK: Messages and handlers

struct BoomAfterInsert: Error {}

/// Inserts two rows, then fails if asked. Transactional: both rows must disappear on failure.
struct TransferTwo: SwiftMediator.Request, Transactional, Content {
    typealias Response = Int
    let fail: Bool
}

/// Same work, not transactional: on failure the first two rows stay.
struct TransferTwoUnguarded: SwiftMediator.Request, Content {
    typealias Response = Int
    let fail: Bool
}

@Handler
struct TransferTwoHandler: RequestHandler {
    let db: any Database          // the transaction's connection inside FluentTransaction
    func handle(_ request: TransferTwo) async throws -> Int {
        try await Ledger(amount: 10).save(on: db)
        try await Ledger(amount: 20).save(on: db)
        if request.fail { throw BoomAfterInsert() }
        return try await Ledger.query(on: db).count()
    }
}

@Handler
struct TransferTwoUnguardedHandler: RequestHandler {
    let db: any Database
    func handle(_ request: TransferTwoUnguarded) async throws -> Int {
        try await Ledger(amount: 10).save(on: db)
        try await Ledger(amount: 20).save(on: db)
        if request.fail { throw BoomAfterInsert() }
        return try await Ledger.query(on: db).count()
    }
}

/// Reports whether it was built inside a transaction.
struct WhereAmI: SwiftMediator.Request, Transactional { typealias Response = Bool }
@Handler
struct WhereAmIHandler: RequestHandler {
    let inTransaction: Bool
    init(resolver: any Resolver) throws { inTransaction = CurrentDatabase.transaction != nil }
    func handle(_ request: WhereAmI) async throws -> Bool { inTransaction }
}

// MARK: A database that keeps transaction closures

/// SQLite that keeps every transaction closure it is given, as an event-loop future chain
/// may for a moment after the transaction completes.
struct RetainingConfiguration: DatabaseConfiguration {
    var base: any DatabaseConfiguration
    var middleware: [any AnyModelMiddleware] {
        get { base.middleware }
        set { base.middleware = newValue }
    }
    func makeDriver(for databases: Databases) -> any DatabaseDriver { RetainingDriver(base: base.makeDriver(for: databases)) }
}

struct RetainingDriver: DatabaseDriver {
    let base: any DatabaseDriver
    func makeDatabase(with context: DatabaseContext) -> any Database { RetainingDatabase(base: base.makeDatabase(with: context)) }
    func shutdown() { base.shutdown() }
    func shutdownAsync() async { await base.shutdownAsync() }
}

final class KeptClosures: @unchecked Sendable {
    static let shared = KeptClosures()
    private let lock = NSLock()
    private var closures: [Any] = []
    func keep(_ closure: Any) { lock.withLock { closures.append(closure) } }
}

struct RetainingDatabase: Database {
    let base: any Database
    var context: DatabaseContext { base.context }
    var inTransaction: Bool { base.inTransaction }
    func execute(query: DatabaseQuery, onOutput: @escaping @Sendable (any DatabaseOutput) -> ()) -> EventLoopFuture<Void> {
        base.execute(query: query, onOutput: onOutput)
    }
    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> { base.execute(schema: schema) }
    func execute(enum: DatabaseEnum) -> EventLoopFuture<Void> { base.execute(enum: `enum`) }
    func transaction<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        KeptClosures.shared.keep(closure)
        return base.transaction(closure)
    }
    func withConnection<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        base.withConnection(closure)
    }
}

// MARK: Harness

func withFluentApp(keepingTransactionClosures: Bool = false, _ body: (Application) async throws -> Void) async throws {
    let app = try await Application.make(.testing)
    app.resolver = SimpleResolver()
    app.mediatorDiscovery = .thisModule()
    if keepingTransactionClosures {
        app.databases.use(RetainingConfiguration(base: DatabaseConfigurationFactory.sqlite(.memory).make()), as: .sqlite)
    } else {
        app.databases.use(.sqlite(.memory), as: .sqlite)
    }
    app.migrations.add(CreateLedger())
    try await app.autoMigrate()
    app.useFluentTransactions()
    app.post("transfer") { req in try await req.send(TransferTwo.self) }
    app.post("transfer-unguarded") { req in try await req.send(TransferTwoUnguarded.self) }
    app.get("where") { req in try await req.mediator.send(WhereAmI()) ? "txn" : "none" }
    do {
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

@Suite struct FluentTransactionTests {

    @Test func commitsWhenTheHandlerReturns() async throws {
        try await withFluentApp { app in
            try await app.testing().test(.POST, "transfer", beforeRequest: { try $0.content.encode(TransferTwo(fail: false)) }) { res in
                #expect(res.status == .ok, "\(res.body.string)")
                let count = try res.content.decode(Int.self)
                #expect(count == 2)
            }
            #expect(try await Ledger.query(on: app.db).count() == 2)
        }
    }

    @Test func rollsBackWhenTheHandlerThrows() async throws {
        try await withFluentApp { app in
            try await app.testing().test(.POST, "transfer", beforeRequest: { try $0.content.encode(TransferTwo(fail: true)) }) { res in
                #expect(res.status == .internalServerError, "\(res.body.string)")
            }
            #expect(try await Ledger.query(on: app.db).count() == 0, "both inserts rolled back")
        }
    }

    @Test func nonTransactionalRequestsKeepPartialWrites() async throws {
        try await withFluentApp { app in
            try await app.testing().test(.POST, "transfer-unguarded", beforeRequest: { try $0.content.encode(TransferTwoUnguarded(fail: true)) }) { res in
                #expect(res.status == .internalServerError, "\(res.body.string)")
            }
            #expect(try await Ledger.query(on: app.db).count() == 2, "no transaction, so the rows stay")
        }
    }

    @Test func survivesADatabaseThatKeepsTheTransactionClosure() async throws {
        try await withFluentApp(keepingTransactionClosures: true) { app in
            try await app.testing().test(.POST, "transfer", beforeRequest: { try $0.content.encode(TransferTwo(fail: false)) }) { res in
                #expect(res.status == .ok, "\(res.body.string)")
                let count = try res.content.decode(Int.self)
                #expect(count == 2)
            }
        }
    }

    @Test func handlerIsConstructedInsideTheTransaction() async throws {
        try await withFluentApp { app in
            try await app.testing().test(.GET, "where") { res in
                #expect(res.body.string == "txn")
            }
        }
    }
}
#endif
