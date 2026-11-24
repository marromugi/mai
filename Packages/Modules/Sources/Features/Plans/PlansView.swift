import StoreKit
import SwiftUI

/// The plans that pay for syncing, pushed from the settings, with their prices as the App Store
/// gives them. A plan is bought for the kept account ID, or a new one; the screen ends at the
/// purchase.
struct PlansView: View {
  var kept = KeptAccountID.standard
  /// Nil while the App Store is being asked.
  @State private var products: Result<[Product], any Error>?
  /// Counts the 「もう一度」 taps, so each asks the App Store again.
  @State private var attempt = 0
  @State private var buying: SyncPlan?
  @State private var bought: PlanOffer?
  @State private var notice: PlanNotice?
  @Environment(\.purchase) private var purchase

  var body: some View {
    Group {
      switch products {
      case nil:
        ProgressView()
      case .failure(let error):
        PlansUnavailable(reason: appStoreFailureMessage(error)) { attempt += 1 }
      case .success(let products):
        let offers = PlanOffer.all(in: products)
        if let bought {
          PlanBought(offer: bought)
        } else if offers.isEmpty {
          PlansUnavailable(reason: "App Store にプランが見つかりませんでした。") { attempt += 1 }
        } else {
          PlanList(offers: offers, buying: buying) { offer in
            guard let product = products.first(where: { $0.id == offer.plan.productID }) else {
              preconditionFailure("An offer is made only from a product the App Store gave")
            }
            buying = offer.plan
            Task { await buy(offer, product) }
          }
        }
      }
    }
    .navigationTitle("同期のプラン")
    .navigationBarTitleDisplayMode(.inline)
    .task(id: attempt) {
      products = nil
      do {
        products = .success(try await Product.products(for: SyncPlan.allCases.map(\.productID)))
      } catch {
        plansLogger.error("The plans couldn't be loaded: \(error)")
        products = .failure(error)
      }
    }
    .alert(
      Text(verbatim: notice?.title ?? ""),
      isPresented: Binding(get: { notice != nil }, set: { _ in notice = nil }), presenting: notice
    ) { _ in
    } message: { notice in
      Text(verbatim: notice.message)
    }
  }

  /// Buys the plan `buying` names, set by the tap that starts it so a second tap finds the
  /// buttons dimmed.
  private func buy(_ offer: PlanOffer, _ product: Product) async {
    defer { buying = nil }
    do {
      switch try await buyPlan(
        product, keptIn: kept, purchase: { try await purchase($0, options: $1) })
      {
      case .bought:
        bought = offer
      case .waiting:
        notice = .waiting
      case .cancelled:
        break
      }
    } catch {
      notice = .failed(error)
    }
  }
}

/// A plan with its monthly price.
struct PlanOffer: Identifiable {
  let plan: SyncPlan
  let price: String

  var id: SyncPlan { plan }

  /// The plans found among `products`, in the order of `SyncPlan`.
  static func all(in products: [Product]) -> [PlanOffer] {
    SyncPlan.allCases.compactMap { plan in
      products.first { $0.id == plan.productID }.map {
        PlanOffer(plan: plan, price: $0.displayPrice)
      }
    }
  }
}

private enum PlanNotice {
  case waiting
  case failed(PlanPurchaseError)

  var title: String {
    switch self {
    case .waiting: "承認を待っています"
    case .failed: "購入できませんでした"
    }
  }

  var message: String {
    switch self {
    case .waiting: "承認されると購入が済みます。"
    case .failed(let error): error.localizedDescription
    }
  }
}

/// Shown in place of the plans when the App Store couldn't give them, with `reason` and a button
/// that calls `retry`.
struct PlansUnavailable: View {
  let reason: String
  let retry: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label("プランを読み込めませんでした", systemImage: "exclamationmark.triangle")
    } description: {
      Text(verbatim: reason)
    } actions: {
      Button("もう一度", action: retry)
    }
  }
}

/// Shown in place of the plans once `offer` is bought.
struct PlanBought: View {
  let offer: PlanOffer

  var body: some View {
    ContentUnavailableView(
      "\(offer.plan.name)に入りました", systemImage: "checkmark.circle",
      description: Text("月 \(offer.price) の購読です。"))
  }
}

/// iOS's grouped list of `offers`, a section each, whose button calls `buy`. While `buying` is a
/// plan, every button is dimmed and that plan's shows it is under way.
struct PlanList: View {
  let offers: [PlanOffer]
  let buying: SyncPlan?
  let buy: (PlanOffer) -> Void

  var body: some View {
    Form {
      Section {
      } footer: {
        Text("プランに入ると、文書を暗号化して、ほかの端末とそろえます。入らなくても、文書はこの端末の中で今までどおり書けます。")
      }
      ForEach(offers) { offer in
        Section(offer.plan.name) {
          LabeledContent("月額", value: offer.price)
          LabeledContent("文書", value: offer.plan.writings)
          LabeledContent("写真", value: offer.plan.photos)
          Button {
            buy(offer)
          } label: {
            HStack {
              Text("\(offer.plan.name)に入る")
              Spacer()
              if buying == offer.plan {
                ProgressView()
              }
            }
          }
          .disabled(buying != nil)
        }
      }
      Section {
      } footer: {
        Text("購読は 1 か月ごとに自動で更新されます。解約は App Store の購読の設定からできます。")
      }
    }
  }
}
