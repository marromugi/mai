import Foundation
import Observation
internal import Sync

/// Syncs the writings on the device with the account's on the server, while signed in with the
/// account's own key: when the app comes to the front, when the person asks, and after edits
/// settle. Nothing is sent while signed out.
///
/// Edits are saved on the device at every settled keystroke, but reach the server only through a
/// sync, which sends each changed writing once: a sync runs once edits have paused for `pause`,
/// and no sooner than `interval` after the last one started.
@Observable final class WritingSync {
  enum Status: Equatable {
    case notYet
    case syncing
    case synced(Date)
    /// What went wrong, written for a person.
    case failed(String)
    /// The plan's limit (429) or its lapse (402), written for a person. Edits don't start a sync
    /// until the person asks for one or the app comes to the front again.
    case stopped(String)
  }

  private let account: AccountModel
  private let writings: SyncedWritings
  private let pause: Duration
  private let interval: Duration
  private(set) var status = Status.notYet
  /// One per session and own key, so its syncs run one after the other.
  @ObservationIgnored private var synchronizer: (keys: SyncKeys, synchronizer: Synchronizer)?
  @ObservationIgnored private var lastStarted: ContinuousClock.Instant?
  /// The sync an edit set to run; nil once it has started.
  @ObservationIgnored private(set) var pending: Task<Void, Never>?
  /// The last sync asked for. Each waits for the one before, even on another `Synchronizer`, since
  /// they share the account's state file and the library's take-in.
  @ObservationIgnored private var running: Task<Void, Never>?

  init(
    account: AccountModel, library: WritingLibrary, pause: Duration = .seconds(30),
    interval: Duration = .seconds(300)
  ) {
    self.account = account
    writings = SyncedWritings(library: library)
    self.pause = pause
    self.interval = interval
  }

  /// Syncs now, after any sync already running. Does nothing while signed out or while the own
  /// key isn't the account's.
  func syncNow() async {
    let previous = running
    let task = Task {
      await previous?.value
      await syncOnce()
    }
    running = task
    await task.value
  }

  private func syncOnce() async {
    let keys: SyncKeys
    do {
      guard let settled = try await account.syncKeys() else { return }
      keys = settled
    } catch {
      status = .failed(error.localizedDescription)
      return
    }
    lastStarted = .now
    status = .syncing
    do {
      _ = try await synchronizer(for: keys).sync()
      status = .synced(.now)
    } catch let error as SyncFailures
      where error.failures.values.allSatisfy({ $0 is EditedDuringSync })
    {
      // The edit made during the sync set the next one.
      status = .synced(.now)
    } catch let error as ServerError {
      switch error {
      case .refused(status: 402, _), .refused(status: 429, _):
        status = .stopped(error.localizedDescription)
      case .refused(status: 401, _):
        status = .failed(error.localizedDescription)
        // Drops the ended session, so the section offers signing in again.
        await account.check()
      default:
        status = .failed(error.localizedDescription)
      }
    } catch {
      status = .failed(error.localizedDescription)
    }
  }

  /// Called after each edit saved on the device: sets a sync to run once edits pause.
  func edited() {
    guard account.phase == .signedIn else { return }
    if case .stopped = status { return }
    pending?.cancel()
    let due = Self.due(
      editedAt: .now, lastStarted: lastStarted, pause: pause, interval: interval)
    pending = Task {
      do {
        try await Task.sleep(until: due)
      } catch {
        return
      }
      pending = nil
      await syncNow()
    }
  }

  /// When a sync set by an edit at `editedAt` runs: once edits have paused for `pause`, and no
  /// sooner than `interval` after the last sync started.
  static func due(
    editedAt: ContinuousClock.Instant, lastStarted: ContinuousClock.Instant?, pause: Duration,
    interval: Duration
  ) -> ContinuousClock.Instant {
    let settled = editedAt + pause
    guard let lastStarted else { return settled }
    return max(settled, lastStarted + interval)
  }

  private func synchronizer(for keys: SyncKeys) -> Synchronizer {
    if let synchronizer, synchronizer.keys == keys {
      return synchronizer.synchronizer
    }
    let made = account.synchronizer(for: writings, keys: keys)
    synchronizer = (keys, made)
    return made
  }
}
