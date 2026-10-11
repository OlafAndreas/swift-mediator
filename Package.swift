// swift-tools-version: 6.0
import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "SwiftMediator",
    platforms: [.macOS(.v13), .iOS(.v16), .tvOS(.v16), .watchOS(.v9), .visionOS(.v1)],
    products: [
        /// Core mediator. No third-party runtime dependencies.
        .library(name: "SwiftMediator", targets: ["SwiftMediator"]),
        /// Core + Factory (hmlongco/Factory) integration. Re-exports both.
        .library(name: "SwiftMediatorFactory", targets: ["SwiftMediatorFactory"]),
        /// Swift Testing support for the core: `.resolver` trait, stubs, recorders.
        .library(name: "SwiftMediatorTesting", targets: ["SwiftMediatorTesting"]),
        .executable(name: "Example", targets: ["Example"]),
        .executable(name: "OrderExample", targets: ["OrderExample"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"605.0.0"),
        .package(url: "https://github.com/hmlongco/Factory.git", from: "3.4.0"),
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
        // Factory binding: Container.mediator, FactoryResolver.
        .target(
            name: "SwiftMediatorFactory",
            dependencies: [
                "SwiftMediator",
                .product(name: "FactoryKit", package: "Factory"),
            ]
        ),
        // Testing support: per-test SimpleResolver.shared, event/request recorders.
        .target(
            name: "SwiftMediatorTesting",
            dependencies: ["SwiftMediator"]
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
                .product(name: "FactoryTesting", package: "Factory"),
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
