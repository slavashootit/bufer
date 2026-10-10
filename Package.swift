// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Bufer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Bufer",
            path: "Sources/Bufer",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
