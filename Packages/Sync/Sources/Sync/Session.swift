import Foundation

/// This device's session on the server, and whose it is.
public struct Session: Sendable, Equatable, Codable {
  /// `s1.<session ID>.<secret>`, sent as `Authorization: Bearer`.
  public let token: String
  public let account: UUID
  /// Apple's ID for the user who signed in, whose credential state is checked at launch.
  public let appleUser: String

  public init(token: String, account: UUID, appleUser: String) {
    self.token = token
    self.account = account
    self.appleUser = appleUser
  }
}

/// Where the session is kept: `SessionKeychain` on a device.
public protocol SessionStore: Sendable {
  /// The session kept, or nil when the device is signed out.
  func load() throws(KeychainError) -> Session?
  /// Keeps `session` in place of any kept before.
  func save(_ session: Session) throws(KeychainError)
  func remove() throws(KeychainError)
}
