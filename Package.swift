// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "DemoLogic", platforms: [.macOS(.v12), .iOS(.v15)], products: [.library(name: "DemoLogic", targets: ["DemoLogic"])], targets: [
    .target(name: "DemoLogic", path: "Core"),
    .testTarget(name: "DemoLogicTests", dependencies: ["DemoLogic"], path: "Tests")
])
