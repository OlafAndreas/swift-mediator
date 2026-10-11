// swift-tools-version: 6.1
import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "SwiftMediator",
    platforms: [.macOS(.v13), .iOS(.v16), .tvOS(.v16), .watchOS(.v9), .visionOS(.v1)],
    products: [
        /// Core mediator. No third-party runtime dependencies.
        .library(name: "SwiftMediator", targets: ["SwiftMediator"]),
        /// Swift Testing support for the core: `.resolver` trait, stubs, recorders.
        .library(name: "SwiftMediatorTesting", targets: ["SwiftMediatorTesting"]),
        /// Core + Factory (hmlongco/Factory). Requires the `Factory` trait.
        .library(name: "SwiftMediatorFactory", targets: ["SwiftMediatorFactory"]),
        /// Core + Vapor glue: `req.mediator`, request-scoped values. Requires the `Vapor` trait.
        .library(name: "SwiftMediatorVapor", targets: ["SwiftMediatorVapor"]),
        /// Vapor + Fluent: transaction behavior for `Transactional` requests. Requires the `Fluent` trait.
        .library(name: "SwiftMediatorFluent", targets: ["SwiftMediatorFluent"]),
        .executable(name: "Example", targets: ["Example"]),
        .executable(name: "OrderExample", targets: ["OrderExample"]),
        .executable(name: "VaporExample", targets: ["VaporExample"]),
        .executable(name: "Benchmarks", targets: ["Benchmarks"]),
    ],
    traits: [
        .trait(name: "Factory", description: "Enables SwiftMediatorFactory and fetches hmlongco/Factory."),
        .trait(name: "Vapor", description: "Enables SwiftMediatorVapor and fetches vapor/vapor."),
        .trait(name: "Fluent", description: "Enables SwiftMediatorFluent and fetches vapor/fluent. Implies Vapor.", enabledTraits: ["Vapor"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"605.0.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin.git", from: "1.4.0"),
        // Fetched only when a target depends on them under an enabled trait.
        .package(url: "https://github.com/hmlongco/Factory.git", from: "3.4.0"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.122.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.13.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.9.0"),
    ],
    targets: [
        // Core: protocols, Mediator, Resolver seam, binary-section discovery, macro declarations.
        .target(
            name: "SwiftMediator",
            dependencies: ["SwiftMediatorMacros", "SwiftMediatorSectionShim"]
        ),
        // C shim exposing the ELF section bounds on Linux. No-op elsewhere.
        .target(
            name: "SwiftMediatorSectionShim"
        ),
        // Testing support: per-test SimpleResolver.shared, event/request recorders.
        .target(
            name: "SwiftMediatorTesting",
            dependencies: ["SwiftMediator"]
        ),
        // Factory binding: Container.mediator, FactoryResolver. Empty without the trait.
        .target(
            name: "SwiftMediatorFactory",
            dependencies: [
                "SwiftMediator",
                .product(name: "FactoryKit", package: "Factory", condition: .when(traits: ["Factory"])),
            ]
        ),
        // Vapor binding: Application.mediator, Request.mediator. Empty without the trait.
        .target(
            name: "SwiftMediatorVapor",
            dependencies: [
                "SwiftMediator",
                .product(name: "Vapor", package: "vapor", condition: .when(traits: ["Vapor"])),
            ]
        ),
        // Fluent binding: FluentTransaction behavior, CurrentDatabase. Empty without the trait.
        .target(
            name: "SwiftMediatorFluent",
            dependencies: [
                "SwiftMediatorVapor",
                .product(name: "Fluent", package: "fluent", condition: .when(traits: ["Fluent"])),
            ]
        ),
        // Compiler plugin implementing @Handler / @Behavior.
        .macro(
            name: "SwiftMediatorMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .executableTarget(
            name: "Example",
            dependencies: ["SwiftMediator"]
        ),
        .executableTarget(
            name: "OrderExample",
            dependencies: ["SwiftMediatorFactory"]
        ),
        .executableTarget(
            name: "VaporExample",
            dependencies: ["SwiftMediatorVapor"]
        ),
        .executableTarget(
            name: "Benchmarks",
            dependencies: ["SwiftMediator"]
        ),
        .testTarget(
            name: "SwiftMediatorTests",
            dependencies: ["SwiftMediator"]
        ),
        .testTarget(
            name: "SwiftMediatorTestingTests",
            dependencies: ["SwiftMediatorTesting"]
        ),
        .testTarget(
            name: "SwiftMediatorFactoryTests",
            dependencies: [
                "SwiftMediatorFactory",
                .product(name: "FactoryTesting", package: "Factory", condition: .when(traits: ["Factory"])),
            ]
        ),
        .testTarget(
            name: "SwiftMediatorVaporTests",
            dependencies: [
                "SwiftMediatorVapor",
                .product(name: "VaporTesting", package: "vapor", condition: .when(traits: ["Vapor"])),
                .target(name: "SwiftMediatorFactory", condition: .when(traits: ["Factory"])),
            ]
        ),
        .testTarget(
            name: "SwiftMediatorFluentTests",
            dependencies: [
                "SwiftMediatorFluent",
                .product(name: "VaporTesting", package: "vapor", condition: .when(traits: ["Fluent"])),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver", condition: .when(traits: ["Fluent"])),
            ]
        ),
        .testTarget(
            name: "SwiftMediatorMacrosTests",
            dependencies: [
                "SwiftMediatorMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ]
)
