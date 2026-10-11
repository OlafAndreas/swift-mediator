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

// MARK: Harness

func withFluentApp(_ body: (Application) async throws -> Void) async throws {
    let app = try await Application.make(.testing)
    app.resolver = SimpleResolver()
    app.databases.use(.sqlite(.memory), as: .sqlite)
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
                #expect(res.status == .ok)
                let count = try res.content.decode(Int.self)
                #expect(count == 2)
            }
            #expect(try await Ledger.query(on: app.db).count() == 2)
        }
    }

    @Test func rollsBackWhenTheHandlerThrows() async throws {
        try await withFluentApp { app in
            try await app.testing().test(.POST, "transfer", beforeRequest: { try $0.content.encode(TransferTwo(fail: true)) }) { res in
                #expect(res.status == .internalServerError)
            }
            #expect(try await Ledger.query(on: app.db).count() == 0, "both inserts rolled back")
        }
    }

    @Test func nonTransactionalRequestsKeepPartialWrites() async throws {
        try await withFluentApp { app in
            try await app.testing().test(.POST, "transfer-unguarded", beforeRequest: { try $0.content.encode(TransferTwoUnguarded(fail: true)) }) { res in
                #expect(res.status == .internalServerError)
            }
            #expect(try await Ledger.query(on: app.db).count() == 2, "no transaction, so the rows stay")
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
