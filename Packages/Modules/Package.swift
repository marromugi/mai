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
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.7"),
    .package(path: "../Typesetting"),
    .package(path: "../Sync"),
  ],
  targets: [
    .target(
      name: "Features",
      dependencies: [
        .product(name: "Typesetting", package: "Typesetting"),
        .product(name: "Sync", package: "Sync"),
      ],
      resources: [.copy("Resources/Fonts"), .process("Resources/Icons.xcassets")],
      swiftSettings: mainActor),
    .testTarget(
      name: "FeaturesTests",
      dependencies: [
        "Features",
        .product(name: "Typesetting", package: "Typesetting"),
        .product(name: "Sync", package: "Sync"),
        .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
      ],
      exclude: ["Shared/Fonts/Fixtures"],
      swiftSettings: mainActor),
  ]
)
