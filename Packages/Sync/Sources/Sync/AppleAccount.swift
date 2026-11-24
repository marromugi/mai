import Foundation

/// What Sign in with Apple gives the app for one sign-in.
public struct AppleCredential: Sendable {
  /// Apple's ID for the user, the same on each of the user's devices for this app.
  public let user: String
  /// The ID token (a JWT), made for the nonce the sign-in was asked with.
  public let identityToken: String
  /// The code the server trades with Apple for the user's refresh token.
  public let authorizationCode: String

  public init(user: String, identityToken: String, authorizationCode: String) {
    self.user = user
    self.identityToken = identityToken
    self.authorizationCode = authorizationCode
  }
}

/// Whether the user still lets this app sign in with Apple, as Apple tells it.
public enum AppleCredentialState: Sendable {
  case authorized
  /// The user stopped using Sign in with Apple with this app.
  case revoked
  /// Apple knows no such user for this app.
  case notFound
  /// The app was moved to another team.
  case transferred
}

/// Sign in with Apple. `AuthenticationServices` on a device; a stand-in (`StandInApple`) where Apple
/// can't be reached, such as the tests.
public protocol AppleSignIn: Sendable {
  /// Asks the person to sign in, with `nonce` put in the ID token. Throws `CancellationError` when
  /// they cancel.
  func signIn(nonce: String) async throws -> AppleCredential

  func credentialState(of user: String) async throws -> AppleCredentialState
}

/// A subscription as StoreKit 2 signs it: the transaction and the renewal info, each a
/// `jwsRepresentation`.
public struct SignedSubscription: Sendable {
  public let transaction: String
  public let renewalInfo: String

  public init(transaction: String, renewalInfo: String) {
    self.transaction = transaction
    self.renewalInfo = renewalInfo
  }
}

/// The plans this App Store account pays for. StoreKit 2 on a device; a stand-in where the App
/// Store's signature can't be had.
public protocol Purchases: Sendable {
  /// The current subscriptions to a plan bought for `account`.
  func subscriptions(for account: UUID) async throws -> [SignedSubscription]
}
