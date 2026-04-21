// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "VirtualHID",
    products: [
        .executable(name: "injector", targets: ["InjectorCLI"]),
        .executable(name: "focus-holder", targets: ["FocusHolderApp"])
    ],
    targets: [
        .executableTarget(
            name: "InjectorCLI",
            path: "Sources/InjectorCLI"
        ),
        .executableTarget(
            name: "FocusHolderApp",
            path: "Sources/FocusHolderApp"
        )
    ]
)
