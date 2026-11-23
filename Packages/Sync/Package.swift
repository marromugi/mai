// swift-tools-version: 6.2
import PackageDescription

let concurrency: [SwiftSetting] = [.enableUpcomingFeature("NonisolatedNonsendingByDefault")]

let package = Package(
  name: "Sync",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: [
    .library(name: "Sync", targets: ["Sync"])
  ],
  targets: [
    .target(name: "Sync", swiftSettings: concurrency),
    .testTarget(name: "SyncTests", dependencies: ["Sync"], swiftSettings: concurrency),
  ]
)
