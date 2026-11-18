// swift-tools-version: 6.2
import PackageDescription

let concurrency: [SwiftSetting] = [.enableUpcomingFeature("NonisolatedNonsendingByDefault")]
let mainActor: [SwiftSetting] = concurrency + [.defaultIsolation(MainActor.self)]

let package = Package(
  name: "Modules",
  platforms: [.iOS(.v26)],
  products: [
    .library(name: "Features", targets: ["Features"])
  ],
  targets: [
    .target(name: "Features", swiftSettings: mainActor)
  ]
)
