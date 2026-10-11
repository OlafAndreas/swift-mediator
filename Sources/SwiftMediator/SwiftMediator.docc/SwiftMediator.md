# ``SwiftMediator``

A MediatR-style mediator for Swift with zero registration code.

## Overview

Define a request, write a handler, send. Handlers and pipeline behaviors are discovered at
startup from records the ``Handler()`` and ``Behavior()`` macros place in the binary, so
there is nothing to register. Dependencies arrive as plain stored properties through a
small resolver with lifetimes, environments and per-call scopes, or through Factory if you
prefer. Vapor and Fluent bindings turn a route into one line and wrap handlers in
transactions.

```swift
struct CreateUser: Request {
    struct Response: Sendable { let id: Int }
    let name: String
}

@Handler
struct CreateUserHandler: RequestHandler {
    let users: UserRepository
    func handle(_ request: CreateUser) async throws -> CreateUser.Response {
        .init(id: try await users.insert(name: request.name))
    }
}

let mediator = try Mediator()
let user = try await mediator.send(CreateUser(name: "Olaf"))
```

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:RequestsAndEvents>
- <doc:Handlers>

### The pipeline

- <doc:PipelineBehaviors>
- <doc:PublishingEvents>
- <doc:FailFast>

### Dependencies

- <doc:DependencyInjection>
- <doc:ScopesAndLifetimes>
- <doc:Environments>

### Discovery

- <doc:HowDiscoveryWorks>

### Testing

- <doc:Testing>

### Integrations

- <doc:VaporIntegration>
- <doc:FluentTransactions>
- <doc:FactoryIntegration>

### Reference

- <doc:Performance>
- ``Mediator``
- ``Request``
- ``Event``
- ``RequestHandler``
- ``EventHandler``
- ``PipelineBehavior``
- ``Resolver``
- ``SimpleResolver``
- ``Discovery``
- ``MediatorError``
