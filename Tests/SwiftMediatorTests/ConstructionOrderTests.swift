import Testing
import SwiftMediator

enum Ambient {
    @TaskLocal static var label = "none"
}

struct Snapshot: Sendable { let label: String }
struct WhatLabel: Request { typealias Response = String }

/// Captures the task-local at construction time, not at handle time.
struct LabelHandler: RequestHandler {
    let snapshot: Snapshot
    init(resolver: any Resolver) throws { snapshot = try resolver() }
    func handle(_ request: WhatLabel) async throws -> String { snapshot.label }
}

/// Sets the task-local around `next`. Everything inside is built within it.
struct Labeller: PipelineBehavior {
    static var order: Int { -10 }
    init(resolver: any Resolver) throws {}
    func handle<R: Request>(_ request: R, next: Next<R>) async throws -> R.Response {
        try await Ambient.$label.withValue("inside") { try await next(request) }
    }
}

/// Also captures at construction, and sits inside Labeller.
struct InnerProbe: PipelineBehavior {
    static var order: Int { 10 }
    let snapshot: Snapshot
    init(resolver: any Resolver) throws { snapshot = try resolver() }
    func handle<R: Request>(_ request: R, next: Next<R>) async throws -> R.Response {
        let response = try await next(request)
        if let text = response as? String { return "\(snapshot.label)/\(text)" as! R.Response }
        return response
    }
}

@Suite struct ConstructionOrderTests {

    @Test func componentsAreBuiltInsideTheBehaviorsOutsideThem() async throws {
        let resolver = SimpleResolver()
        resolver.register(Snapshot.self) { _ in Snapshot(label: Ambient.label) }   // reads the task-local
        let mediator = try Mediator(resolver: resolver, discovery: false) {
            $0.register(LabelHandler.self)
            $0.register(Labeller.self)
            $0.register(InnerProbe.self)
        }

        // InnerProbe and LabelHandler are constructed inside Labeller's withValue.
        #expect(try await mediator.send(WhatLabel()) == "inside/inside")
    }

    @Test func constructionFailuresSurfaceInsideThePipeline() async throws {
        struct Recorder: PipelineBehavior {
            static var order: Int { -100 }
            init(resolver: any Resolver) throws {}
            func handle<R: Request>(_ request: R, next: Next<R>) async throws -> R.Response {
                do { return try await next(request) } catch is ResolverError { throw Wrapped() }
            }
        }
        struct Wrapped: Error {}

        let mediator = try Mediator(resolver: SimpleResolver(), discovery: false) {   // Snapshot unregistered
            $0.register(LabelHandler.self)
            $0.register(Recorder.self)
        }
        await #expect(throws: Wrapped.self) { _ = try await mediator.send(WhatLabel()) }
    }
}
