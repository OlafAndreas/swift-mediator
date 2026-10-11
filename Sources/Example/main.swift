import SwiftMediator   // core only: no Factory

// MARK: Infrastructure and providers (long-lived)

struct NetworkClient: Sendable {
    func get(_ path: String) -> String { "GET \(path)" }
}

struct UserAPI: Sendable {              // provider: wraps the shared client, lives as long as the app
    let client: NetworkClient
    func create(name: String) -> User { User(id: Int.random(in: 1...999), name: name) }
}

struct User: Sendable { let id: Int; let name: String }

/// One per `send`, shared by every behavior and the handler.
struct RequestContext: Sendable {
    let correlationID = String(UInt32.random(in: 0x1000...0xFFFF), radix: 16)
}

// MARK: Composition root, grouped into modules

struct NetworkingModule: ResolverModule {
    func register(into resolver: SimpleResolver) {
        resolver.register(NetworkClient.self, lifetime: .singleton) { _ in NetworkClient() }
        resolver.register(UserAPI.self, lifetime: .singleton) { r in UserAPI(client: try r()) }
    }
}

struct RequestModule: ResolverModule {
    func register(into resolver: SimpleResolver) {
        resolver.register(RequestContext.self, lifetime: .scoped) { _ in RequestContext() }
    }
}

// MARK: Messages

struct CreateUser: Request {
    typealias Response = User
    let name: String
}

struct UserCreated: Event { let user: User; let correlationID: String }

// MARK: Handlers, discovered automatically

@Handler
struct CreateUserHandler: RequestHandler {
    let api: UserAPI             // singleton from the shared root
    let context: RequestContext  // scoped: the same instance the Logging behavior saw
    let mediator: Mediator       // always available

    func handle(_ request: CreateUser) async throws -> User {
        let user = api.create(name: request.name)
        try await mediator.publish(UserCreated(user: user, correlationID: context.correlationID))
        return user
    }
}

@Handler
struct SendWelcomeEmail: EventHandler {
    func handle(_ event: UserCreated) async throws {
        print("  ✉️  [\(event.correlationID)] welcome mail to \(event.user.name)")
    }
}

@Behavior
struct Logging: PipelineBehavior {
    let context: RequestContext

    func handle<R: Request>(_ request: R, next: Next<R>) async throws -> R.Response {
        print("→ [\(context.correlationID)] \(R.self)")
        let response = try await next(request)
        print("← [\(context.correlationID)] \(R.self) = \(response)")
        return response
    }
}

// MARK: App start

SimpleResolver.shared.install(NetworkingModule(), RequestModule())

let mediator = try Mediator()   // uses SimpleResolver.shared; throws on a broken registry
print("discovered behaviors:", mediator.behaviorTypes)
print("discovered event handlers:", mediator.eventHandlerTypes)

_ = try await mediator.send(CreateUser(name: "Olaf"))
_ = try await mediator.send(CreateUser(name: "Kari"))   // a new RequestContext each time
