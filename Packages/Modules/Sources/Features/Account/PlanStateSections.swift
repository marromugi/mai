import StoreKit
import SwiftUI
internal import Sync

/// The settings' sections for the plan of a signed-in account, after the account's: whether the
/// subscription pays for it, with 「購読を管理」, and what it used of the plan's limits.
struct PlanStateSections: View {
  let state: AccountState
  /// The time 「あと何日」 counts from.
  var now = Date.now
  @State private var managing = false

  var body: some View {
    Section {
      LabeledContent("プラン", value: SyncPlan(rawValue: state.plan)?.name ?? state.plan)
      LabeledContent("状態") {
        switch state.standing {
        case .paid:
          Text("有効")
        case .gracePeriod:
          Text("猶予中")
        case .lapsed:
          Text("期限切れ").foregroundStyle(.red)
        }
      }
      Button("購読を管理") { managing = true }
        .manageSubscriptionsSheet(isPresented: $managing)
    } header: {
      Text("購読")
    } footer: {
      footer
    }
    Section {
      UsageRow(title: "文書の容量", use: state.usage.writingsBytes, unit: .bytes)
      UsageRow(title: "文書の本数", use: state.usage.writings, unit: .count("本"))
      UsageRow(title: "今日の保存", use: state.usage.saves, unit: .count("回"))
      UsageRow(title: "今日の一覧", use: state.usage.lists, unit: .count("回"))
      UsageRow(title: "今日のリクエスト", use: state.usage.requests, unit: .count("回"))
    } header: {
      Text("使った量")
    } footer: {
      Text("右はプランの上限です。今日の回数は、協定世界時の 0 時（日本時間の 9 時）に 0 に戻ります。")
    }
  }

  @ViewBuilder private var footer: some View {
    switch state.standing {
    case .paid(let until):
      Text("\(until, format: Self.day) までの分が払われています。")
    case .gracePeriod(let until):
      Text(
        "App Store がお支払いをやり直しています。\(until, format: Self.day) までに支払いが済まないと期限が切れ、この端末の変更をサーバーに送れなくなります。お支払い方法は「購読を管理」から確かめられます。"
      )
    case .lapsed(let since, let deletesAt):
      let days = Self.daysLeft(from: now, to: deletesAt)
      if days > 0 {
        Text(
          "\(since, format: Self.day) に期限が切れました。この端末の変更はサーバーに送れません。ほかの端末の変更は受け取ります。あと \(days) 日（\(deletesAt, format: Self.day)）で、サーバーの文書は消えます。それまでにプランに入り直すと、消えずにまた同期できます。この端末の文書は残ります。"
        )
      } else {
        Text(
          "\(since, format: Self.day) に期限が切れました。この端末の変更はサーバーに送れません。サーバーの文書は、まもなく消えます。この端末の文書は残ります。"
        )
      }
    }
  }

  private static let day = Date.FormatStyle.dateTime.year().month().day()

  /// Whole days from `now` until `deletesAt`, a part of a day counted as one; 0 once it is past.
  static func daysLeft(from now: Date, to deletesAt: Date) -> Int {
    max(0, Int((deletesAt.timeIntervalSince(now) / (24 * 60 * 60)).rounded(.up)))
  }
}

/// What is used of one limit, beside the limit; in red, saying so, once it is used up.
private struct UsageRow: View {
  enum Unit {
    case bytes
    case count(String)
  }

  let title: LocalizedStringKey
  let use: PlanUsage.Use
  let unit: Unit

  var body: some View {
    LabeledContent(title) {
      if use.isUsedUp {
        Text("\(amount)（上限）").foregroundStyle(.red)
      } else {
        Text(amount)
      }
    }
  }

  private var amount: String {
    switch unit {
    case .bytes:
      "\(use.used.formatted(.byteCount(style: .decimal))) / \(use.limit.formatted(.byteCount(style: .decimal)))"
    case .count(let counter):
      "\(use.used.formatted()) / \(use.limit.formatted()) \(counter)"
    }
  }
}
