// swift-tools-version: 6.2
import PackageDescription

let concurrency: [SwiftSetting] = [.enableUpcomingFeature("NonisolatedNonsendingByDefault")]

let package = Package(
  name: "Agent",
  platforms: [.macOS(.v26)],
  products: [
    .executable(name: "mai-mcp", targets: ["MaiMCP"])
  ],
  dependencies: [
    .package(path: "../Sync"),
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
  ],
  targets: [
    .target(
      name: "Agent",
      dependencies: ["Sync", .product(name: "MCP", package: "swift-sdk")],
      swiftSettings: concurrency),
    .executableTarget(name: "MaiMCP", dependencies: ["Agent"], swiftSettings: concurrency),
    .testTarget(
      name: "AgentTests",
      dependencies: [
        "Agent", .product(name: "SyncFakes", package: "Sync"),
        .product(name: "MCP", package: "swift-sdk"),
      ],
      swiftSettings: concurrency),
  ]
)
