// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TakeList",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TakeList", targets: ["TakeList"]),
    ],
    targets: [
        .target(name: "TakeListCore"),
        .executableTarget(name: "TakeList", dependencies: ["TakeListCore"]),
        .testTarget(name: "TakeListCoreTests", dependencies: ["TakeListCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
