import Foundation
import Sync
import SyncFakes
import Testing

/// How `GET /account` and a 429 read on the device: the Worker's own answers are read in
/// `AccountContractTests`.
struct AccountStateTests {
  private let day: Int64 = 24 * 60 * 60 * 1000

  private func state(_ json: String) async throws -> AccountState {
    try await AccountServer(
      url: try #require(URL(string: "https://worker.test")),
      transport: ScriptedServer(["GET /account": [.status(200, json: json)]])
    ).account(token: "s1.x.y")
  }

  private func date(_ milliseconds: Int64) -> Date {
    Date(timeIntervalSince1970: Double(milliseconds) / 1000)
  }

  @Test func aPaidAccountIsPaidUntilItsPaidUntil() async throws {
    let state = try await state(accountAnswer(check: nil, paidUntil: 30 * day))
    #expect(state.plan == "basic")
    #expect(state.standing == .paid(until: date(30 * day)))
    #expect(state.usage.saves == PlanUsage.Use(used: 0, limit: 500))
    #expect(state.usage.writingsBytes == PlanUsage.Use(used: 0, limit: 100_000_000))
  }

  @Test func anAccountInItsGracePeriodIsPaidUntilItEnds() async throws {
    let state = try await state(accountAnswer(check: nil, paidUntil: 6 * day, gracePeriod: true))
    #expect(state.standing == .gracePeriod(until: date(6 * day)))
  }

  @Test func aLapsedAccountSaysWhenItIsDeleted() async throws {
    let state = try await state(
      accountAnswer(check: nil, paidUntil: day, lapsed: true, deletesAt: 91 * day))
    #expect(state.standing == .lapsed(since: date(day), deletesAt: date(91 * day)))
  }

  @Test(arguments: [
    accountAnswer(check: nil, lapsed: true),
    accountAnswer(check: nil, deletesAt: 91),
    accountAnswer(check: nil, lapsed: true, gracePeriod: true, deletesAt: 91),
    accountAnswer(check: nil).replacing(#""gracePeriod":false,"#, with: ""),
    accountAnswer(check: nil).replacing(#""saves":{"used":0,"limit":500},"#, with: ""),
  ])
  func anAnswerThatDoesntHoldTogetherIsUnexpected(_ json: String) async throws {
    await #expect {
      try await state(json)
    } throws: { error in
      guard case .unexpectedAnswer = error as? ServerError else { return false }
      return true
    }
  }

  @Test func usageAtItsLimitIsUsedUp() {
    #expect(PlanUsage.Use(used: 500, limit: 500).isUsedUp)
    #expect(!PlanUsage.Use(used: 499, limit: 500).isUsedUp)
  }

  @Test(arguments: [
    (#"{"error":"x","limit":"requests"}"#, PlanLimit.requests),
    (#"{"error":"x","limit":"lists"}"#, .lists),
    (#"{"error":"x","limit":"saves"}"#, .saves),
    (#"{"error":"x","limit":"photos"}"#, .photos),
    (#"{"error":"x","limit":"storage"}"#, .storage),
    (#"{"error":"x","limit":"photo-storage"}"#, .photoStorage),
    (#"{"error":"x","limit":"something-new"}"#, nil),
    (#"{"error":"x"}"#, nil),
    ("<html>Too Many Requests</html>", nil),
  ])
  func a429SaysWhichLimitItReached(_ json: String, _ limit: PlanLimit?) async throws {
    let server = AccountServer(
      url: try #require(URL(string: "https://worker.test")),
      transport: ScriptedServer(["GET /account": [.status(429, json: json)]]))
    await #expect {
      try await server.account(token: "s1.x.y")
    } throws: { error in
      guard case .limitReached(let reached) = error as? ServerError else { return false }
      return reached == limit
    }
  }
}
