// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Anyseek", platforms: [.macOS(.v13)], products: [.executable(name: "Anyseek", targets: ["Anyseek"])], targets: [.target(name: "AnyseekCore"), .executableTarget(name: "Anyseek", dependencies: ["AnyseekCore"]), .testTarget(name: "AnyseekCoreTests", dependencies: ["AnyseekCore"])])
