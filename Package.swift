// swift-tools-version: 6.2

import Foundation
import PackageDescription

let environment = ProcessInfo.processInfo.environment

let containerizationPackage: String
let containerization: Package.Dependency
if let path = environment["CONTAINERIZATION_PATH"], !path.isEmpty {
    containerizationPackage = URL(fileURLWithPath: path).lastPathComponent.lowercased()
    containerization = .package(path: path)
} else {
    containerizationPackage = "containerization"
    let version = environment["CONTAINERIZATION_VERSION"] ?? "0.52.1"
    containerization = .package(url: "https://github.com/apple/containerization.git", exact: Version(stringLiteral: version))
}

let package = Package(
    name: "containerization-push-leak",
    platforms: [.macOS("15.0")],
    dependencies: [
        containerization,
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "push-leak-repro",
            dependencies: [
                .product(name: "Containerization", package: containerizationPackage),
                .product(name: "ContainerizationOCI", package: containerizationPackage),
                .product(name: "ContainerizationExtras", package: containerizationPackage),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        )
    ]
)
