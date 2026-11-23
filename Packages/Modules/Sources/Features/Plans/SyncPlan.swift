import Foundation

/// A plan that pays for syncing, each an auto-renewing monthly subscription on the App Store. The
/// raw value is the server's `plans.tier`.
enum SyncPlan: String, CaseIterable, Identifiable {
  case basic
  case plus
  case pro

  var id: Self { self }

  /// The App Store product, the same as the server's `plans.product_id`.
  var productID: String { "com.marromugi.mai.\(rawValue).monthly" }

  var name: String {
    switch self {
    case .basic: "Basic"
    case .plus: "Plus"
    case .pro: "Pro"
    }
  }

  /// How much of the writings the server keeps, by size and by count.
  var writings: String {
    switch self {
    case .basic: "100 MB・10,000 本"
    case .plus: "500 MB・50,000 本"
    case .pro: "1 GB・100,000 本"
    }
  }

  var photos: String {
    switch self {
    case .basic: "5 GB"
    case .plus: "50 GB"
    case .pro: "200 GB"
    }
  }
}
