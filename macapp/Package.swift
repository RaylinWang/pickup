// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Pickup",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Pickup",
            path: "Sources/SessionTracker",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
