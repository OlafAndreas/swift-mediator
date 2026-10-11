import Testing
@testable import SwiftMediator

// MARK: Fixtures

/// Hands out increasing IDs so tests can tell instances apart.
final class Counter: @unchecked Sendable {
    private var next = 0
    private let lock = NSLock()
    func take() -> Int { lock.withLock { next += 1; return next } }
}

struct UnitOfWork: Sendable { let id: Int }
struct Clock: Sendable { let id: Int }
struct Stamp: Sendable { let id: Int }

struct WhichUnit: Request { typealias Response = [Int] }

@Handler
struct WhichUnitHandler: RequestHandler {
    let unit: UnitOfWork
    let clock: Clock
    let stamp: Stamp
    func handle(_ request: WhichUnit) async throws -> [Int] { [unit.id, clock.id, stamp.id] }
}

/// Also takes the scoped UnitOfWork; must see the same instance as the handler.
@Behavior
struct UnitObserver: PipelineBehavior {
    let unit: UnitOfWork
    func handle<R: Request>(_ request: R, next: Next<R>) async throws -> R.Response {
        let response = try await next(request)
        if var ids = response as? [Int] { ids.append(unit.id); return ids as! R.Response }
        return response
    }
}

struct Chain: Request { typealias Response = (outer: Int, inner: Int) }
struct Chained: Event { let report: @Sendable (Int) -> Void }

/// Injects the mediator and the current scope without any registration.
@Handler
struct ChainHandler: RequestHandler {
    let mediator: Mediator
    let scope: any Resolver
    func handle(_ request: Chain) async throws -> (outer: Int, inner: Int) {
        let box = Box()
        try await mediator.publish(Chained(report: { box.value = $0 }))   // nested call
        let unit = try scope.resolve(UnitOfWork.self)                     // lazy, same scope
        return (outer: unit.id, inner: box.value)
    }
}

@Handler
struct ChainedHandler: EventHandler {
    let unit: UnitOfWork
    func handle(_ event: Chained) async throws { event.report(unit.id) }
}

final class Box: @unchecked Sendable { var value = -1 }

// MARK: Tests

@Suite struct ScopeTests {

    func makeResolver() -> (SimpleResolver, Counter) {
        let counter = Counter()
        let resolver = SimpleResolver()
        resolver.register(UnitOfWork.self, lifetime: .scoped) { _ in UnitOfWork(id: counter.take()) }
        resolver.register(Clock.self, lifetime: .singleton) { _ in Clock(id: counter.take()) }
        resolver.register(Stamp.self) { _ in Stamp(id: counter.take()) }   // unique
        return (resolver, counter)
    }

    @Test func scopedInstanceIsSharedByHandlerAndBehaviorsWithinOneSend() async throws {
        let (resolver, _) = makeResolver()
        let mediator = try Mediator(resolver: resolver, discovery: false) {
            $0.register(WhichUnitHandler.self)
            $0.register(UnitObserver.self)
        }

        let ids = try await mediator.send(WhichUnit())
        // [unit (handler), clock, stamp, unit (behavior)]
        #expect(ids[0] == ids[3], "handler and behavior must share the scoped UnitOfWork")
    }

    @Test func scopedInstanceDiffersAcrossSends() async throws {
        let (resolver, _) = makeResolver()
        let mediator = try Mediator(resolver: resolver, discovery: false) { $0.register(WhichUnitHandler.self) }

        let first = try await mediator.send(WhichUnit())
        let second = try await mediator.send(WhichUnit())
        #expect(first[0] != second[0])
    }

    @Test func singletonIsCreatedOnceAndLazily() async throws {
        let (resolver, counter) = makeResolver()
        let mediator = try Mediator(resolver: resolver, discovery: false) { $0.register(WhichUnitHandler.self) }

        #expect(counter.take() == 1, "nothing created before first send")
        let first = try await mediator.send(WhichUnit())
        let second = try await mediator.send(WhichUnit())
        #expect(first[1] == second[1])
    }

    @Test func uniqueIsCreatedEveryResolve() async throws {
        let (resolver, _) = makeResolver()
        let mediator = try Mediator(resolver: resolver, discovery: false) { $0.register(WhichUnitHandler.self) }

        let first = try await mediator.send(WhichUnit())
        let second = try await mediator.send(WhichUnit())
        #expect(first[2] != second[2])
    }

    @Test func scopedOutsideAScopeBehavesAsUnique() throws {
        let (resolver, _) = makeResolver()
        let a = try resolver.resolve(UnitOfWork.self)
        let b = try resolver.resolve(UnitOfWork.self)
        #expect(a.id != b.id)
    }

    @Test func registeredInstanceIsASingleton() throws {
        let resolver = SimpleResolver()
        resolver.register(Clock.self, instance: Clock(id: 42))
        #expect(try resolver.resolve(Clock.self).id == 42)
        #expect(try resolver.resolve(Clock.self).id == 42)
    }

    @Test func nestedCallsThroughInjectedMediatorShareTheOuterScope() async throws {
        let (resolver, _) = makeResolver()
        let mediator = try Mediator(resolver: resolver, discovery: false) {
            $0.register(ChainHandler.self)
            $0.register(ChainedHandler.self)
        }
        let result = try await mediator.send(Chain())
        #expect(result.inner != -1, "nested publish reached the event handler")
        #expect(result.outer == result.inner, "event handler saw the same scoped UnitOfWork")
    }

    @Test func factoriesResolveTheirOwnDependenciesInTheSameScope() async throws {
        struct Pair: Sendable { let a: UnitOfWork; let b: UnitOfWork }
        struct GetPair: Request { typealias Response = Bool }
        struct GetPairHandler: RequestHandler {
            let pair: Pair
            init(resolver: any Resolver) throws { pair = try resolver.resolve(Pair.self) }
            func handle(_ request: GetPair) async throws -> Bool { pair.a.id == pair.b.id }
        }

        let (resolver, _) = makeResolver()
        resolver.register(Pair.self) { r in Pair(a: try r.resolve(UnitOfWork.self), b: try r.resolve(UnitOfWork.self)) }
        let mediator = try Mediator(resolver: resolver, discovery: false) { $0.register(GetPairHandler.self) }

        #expect(try await mediator.send(GetPair()) == true)
    }
}

import Foundation
