import Foundation
import StoreKit
import os

/// The Worker in `Server/` a build talks to: `MaiServer` in its Info.plist (`MAI_SERVER` in
/// `project.yml`), or, in a debug build, the one `MAI_SERVER_URL` names, such as a local
/// `wrangler dev`. A Beta build also names `MaiAppStoreServer`, production's, which it talks to
/// instead when the App Store installed it (Server/README.md「デプロイ」).
public struct ServerAddress: Equatable, Sendable {
  let server: URL
  let appStoreServer: URL?

  public init(info: [String: Any], environment: [String: String]) {
    var address = info["MaiServer"] as? String
    #if DEBUG
      address = environment["MAI_SERVER_URL"] ?? address
    #endif
    server = Self.url(address, named: "MaiServer")
    let appStore = info["MaiAppStoreServer"] as? String ?? ""
    appStoreServer = appStore.isEmpty ? nil : Self.url(appStore, named: "MaiAppStoreServer")
  }

  /// `installedFromAppStore` is nil when StoreKit couldn't say; the build's own server is used then.
  func resolved(installedFromAppStore: Bool?) -> URL {
    if let appStoreServer, installedFromAppStore == true { appStoreServer } else { server }
  }

  /// Whether the App Store installed this app, from StoreKit's app transaction; nil when it can't
  /// be had or verified within `limit`.
  static func installedFromAppStore(within limit: Duration = .seconds(5)) async -> Bool? {
    await withTaskGroup(of: Bool?.self) { group in
      group.addTask { await appTransactionEnvironmentIsProduction() }
      group.addTask {
        try? await Task.sleep(for: limit)
        if !Task.isCancelled { log.error("StoreKit gave no app transaction within \(limit)") }
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }

  private static func appTransactionEnvironmentIsProduction() async -> Bool? {
    do {
      switch try await AppTransaction.shared {
      case .verified(let transaction):
        return transaction.environment == .production
      case .unverified(_, let error):
        log.error("The app transaction wasn't verified: \(error)")
        return nil
      }
    } catch {
      log.error("The app transaction couldn't be had: \(error)")
      return nil
    }
  }

  nonisolated private static let log = Logger(subsystem: "com.marromugi.mai", category: "server")

  private static func url(_ address: String?, named name: String) -> URL {
    guard let address, let url = URL(string: address), url.host() != nil else {
      preconditionFailure("\(name), \(address ?? "none"), isn't a URL.")
    }
    return url
  }
}
