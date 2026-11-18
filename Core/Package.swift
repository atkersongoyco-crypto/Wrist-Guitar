// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AirGuitarCore",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v13)],
    products: [
        .library(name: "AirGuitarCore", targets: ["AirGuitarCore"]),
        .executable(name: "AirGuitarCoreChecks", targets: ["CoreChecks"])
    ],
    targets: [
        .target(name: "AirGuitarCore"),
        .executableTarget(name: "CoreChecks", dependencies: ["AirGuitarCore"], path: "Checks"),
        .testTarget(name: "AirGuitarCoreTests", dependencies: ["AirGuitarCore"])
    ]
)
