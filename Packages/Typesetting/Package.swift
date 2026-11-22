// swift-tools-version: 6.2
import PackageDescription

let concurrency: [SwiftSetting] = [.enableUpcomingFeature("NonisolatedNonsendingByDefault")]

let package = Package(
  name: "Typesetting",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: [
    .library(name: "Typesetting", targets: ["Typesetting"])
  ],
  targets: [
    .target(name: "Typesetting", swiftSettings: concurrency),
    .testTarget(
      name: "TypesettingTests", dependencies: ["Typesetting"], swiftSettings: concurrency),
  ]
)
