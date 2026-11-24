import AuthenticationServices
import StoreKit
internal import Sync
import UIKit

/// Sign in with Apple through `AuthenticationServices`, asking for no name and no email.
nonisolated struct AppleIDSignIn: AppleSignIn {
  func signIn(nonce: String) async throws -> AppleCredential {
    try await AppleIDRequest().perform(nonce: nonce)
  }

  func credentialState(of user: String) async throws -> AppleCredentialState {
    switch try await ASAuthorizationAppleIDProvider().credentialState(forUserID: user) {
    case .authorized: .authorized
    case .revoked: .revoked
    case .notFound: .notFound
    case .transferred: .transferred
    @unknown default: .authorized
    }
  }
}

/// One request to Sign in with Apple, kept alive by `perform` until Apple answers.
private final class AppleIDRequest: NSObject, ASAuthorizationControllerDelegate,
  ASAuthorizationControllerPresentationContextProviding
{
  private var answer: CheckedContinuation<AppleCredential, any Error>?

  func perform(nonce: String) async throws -> AppleCredential {
    let request = ASAuthorizationAppleIDProvider().createRequest()
    request.requestedScopes = []
    request.nonce = nonce
    let controller = ASAuthorizationController(authorizationRequests: [request])
    controller.delegate = self
    controller.presentationContextProvider = self
    return try await withCheckedThrowingContinuation { answer in
      self.answer = answer
      controller.performRequests()
    }
  }

  func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithAuthorization authorization: ASAuthorization
  ) {
    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
      let identityToken = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }),
      let code = credential.authorizationCode.flatMap({ String(data: $0, encoding: .utf8) })
    else {
      finish(.failure(ASAuthorizationError(.invalidResponse)))
      return
    }
    finish(
      .success(
        AppleCredential(
          user: credential.user, identityToken: identityToken, authorizationCode: code)))
  }

  func authorizationController(
    controller: ASAuthorizationController, didCompleteWithError error: any Error
  ) {
    if case ASAuthorizationError.canceled = error {
      finish(.failure(CancellationError()))
    } else {
      finish(.failure(error))
    }
  }

  func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
    guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else {
      preconditionFailure("Sign in with Apple is asked for from a button in a window")
    }
    return window
  }

  private func finish(_ result: Result<AppleCredential, any Error>) {
    answer?.resume(with: result)
    answer = nil
  }
}

/// The plans this App Store account subscribes to, from StoreKit 2.
nonisolated struct StoreKitPurchases: Purchases {
  let productIDs: Set<String>

  func subscriptions(for account: UUID) async throws -> [SignedSubscription] {
    var found: [SignedSubscription] = []
    for await result in Transaction.currentEntitlements {
      guard case .verified(let transaction) = result, productIDs.contains(transaction.productID),
        transaction.appAccountToken == account,
        let status = await transaction.subscriptionStatus
      else { continue }
      found.append(
        SignedSubscription(
          transaction: result.jwsRepresentation,
          renewalInfo: status.renewalInfo.jwsRepresentation))
    }
    return found
  }
}
