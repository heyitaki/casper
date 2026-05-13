// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "casper-swiftc-wrapper",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "casper-swiftc-wrapper", targets: ["casper-swiftc-wrapper"]),
    ],
    targets: [
        .executableTarget(name: "casper-swiftc-wrapper", path: "Sources/casper-swiftc-wrapper"),
        .testTarget(
            name: "casper-swiftc-wrapper-tests",
            dependencies: ["casper-swiftc-wrapper"],
            path: "Tests/casper-swiftc-wrapper-tests"
        ),
    ]
)
