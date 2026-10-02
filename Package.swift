// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SuperUp",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "SuperUp", targets: ["SuperUp"])],
    targets: [
        .target(name: "SuperUpCore"),
        .executableTarget(name: "SuperUp", dependencies: ["SuperUpCore"]),
        .executableTarget(name: "SuperUpChecks", dependencies: ["SuperUpCore"]),
    ]
)
