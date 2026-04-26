// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "VirtualHID",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "injector", targets: ["InjectorCLI"]),
        .executable(name: "focus-holder", targets: ["FocusHolderApp"]),
        .executable(name: "vhid-daemon", targets: ["InjectorDaemon"]),
        .executable(name: "vhid-tray", targets: ["VirtualHIDTray"]),
        .library(name: "InjectorCore", targets: ["InjectorCore"]),
        .library(name: "HumanizationKit", targets: ["HumanizationKit"]),
        .library(name: "Supervisor", targets: ["Supervisor"]),
        .library(name: "ProfileStore", targets: ["ProfileStore"]),
        .library(name: "HIDVisualization", targets: ["HIDVisualization"]),
        .library(name: "ControlServer", targets: ["ControlServer"])
    ],
    targets: [
        .target(
            name: "XCTest",
            path: "Sources/XCTest"
        ),
        .target(
            name: "InjectorCore",
            dependencies: ["HumanizationKit"],
            path: "Sources/InjectorCore",
            exclude: ["README.md"]
        ),
        .target(
            name: "HumanizationKit",
            path: "Sources/HumanizationKit",
            exclude: ["README.md"]
        ),
        .target(
            name: "Supervisor",
            dependencies: ["InjectorCore"],
            path: "Sources/Supervisor"
        ),
        .target(
            name: "ProfileStore",
            dependencies: ["HumanizationKit"],
            path: "Sources/ProfileStore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "HIDVisualization",
            dependencies: ["InjectorCore"],
            path: "Sources/HIDVisualization"
        ),
        .target(
            name: "ControlServer",
            dependencies: ["InjectorCore", "HumanizationKit", "Supervisor", "ProfileStore"],
            path: "Sources/ControlServer"
        ),
        .executableTarget(
            name: "InjectorCLI",
            dependencies: ["InjectorCore", "HumanizationKit"],
            path: "Sources/InjectorCLI"
        ),
        .executableTarget(
            name: "InjectorDaemon",
            dependencies: ["ControlServer", "HIDVisualization", "ProfileStore", "Supervisor"],
            path: "Sources/InjectorDaemon"
        ),
        .executableTarget(
            name: "VirtualHIDTray",
            path: "Sources/VirtualHIDTray"
        ),
        .executableTarget(
            name: "FocusHolderApp",
            path: "Sources/FocusHolderApp"
        ),
        .testTarget(
            name: "InjectorCoreTests",
            dependencies: ["InjectorCore", "XCTest"],
            path: "Tests/InjectorCoreTests"
        ),
        .testTarget(
            name: "HumanizationKitTests",
            dependencies: ["HumanizationKit", "XCTest"],
            path: "Tests/HumanizationKitTests"
        ),
        .testTarget(
            name: "SupervisorTests",
            dependencies: ["Supervisor", "XCTest"],
            path: "Tests/SupervisorTests"
        ),
        .testTarget(
            name: "ProfileStoreTests",
            dependencies: ["ProfileStore", "HumanizationKit", "XCTest"],
            path: "Tests/ProfileStoreTests"
        ),
        .testTarget(
            name: "ControlServerTests",
            dependencies: ["ControlServer", "ProfileStore", "Supervisor", "XCTest"],
            path: "Tests/ControlServerTests"
        )
    ]
)
