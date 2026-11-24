import Sync

extension SyncAccount {
  /// Reads the account with `session`, then settles the own key against it, as the app does.
  func settleOwnKey(_ session: Session) async throws(AccountError) -> OwnKeyOutcome {
    try await settleOwnKey(session, against: state(session))
  }
}
