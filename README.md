<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Assets/wordmark-dark.svg">
    <img src="Assets/wordmark.svg" alt="SwiftMediator" width="440">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/OlafAndreas/swift-mediator/actions/workflows/ci.yml"><img src="https://github.com/OlafAndreas/swift-mediator/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-2F5F9E.svg" alt="MIT license"></a>
  <img src="https://img.shields.io/badge/Swift-6.2%2B-1B8A8F.svg" alt="Swift 6.2+">
  <img src="https://img.shields.io/badge/platforms-macOS%20%7C%20iOS%20%7C%20Linux-2F5F9E.svg" alt="macOS, iOS, Linux">
</p>

A MediatR-style mediator for Swift. Define a request, write a handler, send. Handlers are
discovered from the binary, so there is nothing to register.

## Install

```swift
// Package.swift
.package(url: "https://github.com/OlafAndreas/swift-mediator", from: "0.1.0"),

// target dependencies
.product(name: "SwiftMediator", package: "swift-mediator"),
```

Swift 6.2 or later, macOS, iOS and Linux. Optional bindings are package traits and cost
nothing unless enabled: `traits: ["Factory"]`, `["Vapor"]`, `["Fluent"]`.

## Use

```swift
import SwiftMediator

// 1. A request names its response.
struct CreateUser: Request {
    struct Response: Sendable { let id: Int }
    let name: String
}

// 2. A handler. Dependencies are stored properties; the macro writes the init.
@Handler
struct CreateUserHandler: RequestHandler {
    let users: UserRepository
    func handle(_ request: CreateUser) async throws -> CreateUser.Response {
        .init(id: try await users.insert(name: request.name))
    }
}

// 3. Register long-lived dependencies once, then send.
SimpleResolver.shared.register(UserRepository.self, lifetime: .singleton) { _ in UserRepository() }

let mediator = try Mediator()
let user = try await mediator.send(CreateUser(name: "Olaf"))
```

Add a `@Behavior` for validation, logging, retries or transactions around every send, and
`publish` events to any number of listeners. In Vapor, a route is
`app.post("users") { req in try await req.send(CreateUser.self) }`.

## Documentation

Everything else, from pipeline behaviors and scopes to the Vapor, Fluent and Factory
bindings and the testing utilities, is in the
[documentation](https://olafandreas.github.io/swift-mediator/documentation/swiftmediator/).

Run `swift run Example`, `swift run --traits Factory OrderExample` or
`swift run --traits Vapor VaporExample` to see it working, and `swift test --enable-all-traits`
for the suites.

## License

MIT. See [LICENSE](LICENSE).
