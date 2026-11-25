import SwiftUI
import UniformTypeIdentifiers
import VisionKit

/// Approving an agent: its pairing code read with the camera or typed, then, once approved, the
/// line to hand the agent, shown this once.
struct AgentApprovalView: View {
  /// Answers the line to hand the agent, or what went wrong.
  let approve: (String) async -> Result<String, ApprovalProblem>
  @State private var code = ""
  @State private var problem: String?
  @State private var approving = false
  @State private var scanning = false
  /// The line to hand the agent, once approved.
  @State private var handoff: String?
  @Environment(\.dismiss) private var dismiss

  /// Opened on `handoff`, as once approved, for a look at that page.
  init(
    approve: @escaping (String) async -> Result<String, ApprovalProblem>, handoff: String? = nil
  ) {
    self.approve = approve
    _handoff = State(initialValue: handoff)
  }

  var body: some View {
    Form {
      if let handoff {
        AgentHandoffSections(handoff: handoff)
      } else {
        entrySections
      }
    }
    .navigationTitle(handoff == nil ? "エージェントを承認" : "エージェントに渡す")
    .navigationBarTitleDisplayMode(.inline)
    .interactiveDismissDisabled(handoff != nil)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if handoff == nil {
          Button(role: .cancel) { dismiss() }
        } else {
          Button("完了") { dismiss() }
        }
      }
    }
    .sheet(isPresented: $scanning) {
      QRCodeScanner(
        found: { scanned in
          code = scanned
          scanning = false
        },
        failed: {
          problem = "カメラでコードを読めませんでした。コードを入力してください。"
          scanning = false
        }
      )
      .ignoresSafeArea()
    }
  }

  @ViewBuilder private var entrySections: some View {
    Section {
      TextField("XXXX-XXXX-XXXX-…", text: $code, axis: .vertical)
        .font(.body.monospaced())
        .lineLimit(3...8)
        .textInputAutocapitalization(.characters)
        .autocorrectionDisabled()
        .accessibilityIdentifier("agentCodeEntry")
      if QRCodeScanner.canScan {
        Button("カメラで読む") { scanning = true }
      }
    } footer: {
      if let problem {
        Text(verbatim: problem).foregroundStyle(.red)
      } else {
        Text(
          "エージェントが見せる 56 文字のコードを、カメラで読むか入力します。この端末の自分の鍵で署名して承認し、読み取りモードの間、その鍵あてに文書の鍵を渡します。"
        )
      }
    }
    Section {
      Button("承認する") {
        approving = true
        Task {
          switch await approve(code) {
          case .success(let line):
            problem = nil
            handoff = line
          case .failure(let failure):
            problem = failure.message
          }
          approving = false
        }
      }
      .disabled(code.isEmpty || approving)
    }
  }
}

/// The line an approved agent reads with, to copy or share, shown once.
private struct AgentHandoffSections: View {
  let handoff: String
  @State private var copied = false

  var body: some View {
    Section {
      Text(verbatim: handoff)
        .font(.footnote.monospaced())
        .textSelection(.enabled)
        .accessibilityIdentifier("agentHandoff")
      Button(copied ? "コピーしました" : "コピー") {
        // Universal Clipboard takes it to the Mac; it leaves the clipboard after two minutes.
        UIPasteboard.general.setItems(
          [[UTType.plainText.identifier: handoff]],
          options: [.expirationDate: Date.now.addingTimeInterval(120)])
        copied = true
      }
      ShareLink("共有", item: handoff)
    } footer: {
      Text(
        "この 1 行をエージェントに渡してください。エージェントはこれでサーバーから文書を取ります。ここを閉じると、もう表示できません。なくしたときは、エージェントを取り消して承認し直します。"
      )
    }
  }
}

/// The camera, reading the first QR code it sees.
struct QRCodeScanner: UIViewControllerRepresentable {
  let found: (String) -> Void
  /// Called when the camera can't start.
  let failed: () -> Void

  /// Whether this device's camera can read codes now.
  static var canScan: Bool {
    DataScannerViewController.isSupported && DataScannerViewController.isAvailable
  }

  func makeUIViewController(context: Context) -> DataScannerViewController {
    let scanner = DataScannerViewController(
      recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
    scanner.delegate = context.coordinator
    return scanner
  }

  func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
    context.coordinator.found = found
    // Once: after a code is found, or the camera failed, the sheet is closing.
    guard !context.coordinator.started else { return }
    context.coordinator.started = true
    do {
      try scanner.startScanning()
    } catch {
      readModeLogger.error("The camera couldn't start reading codes: \(error)")
      Task { failed() }
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(found: found)
  }

  final class Coordinator: NSObject, DataScannerViewControllerDelegate {
    var found: (String) -> Void
    var started = false

    init(found: @escaping (String) -> Void) {
      self.found = found
    }

    func dataScanner(
      _ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
      allItems: [RecognizedItem]
    ) {
      for item in addedItems {
        if case .barcode(let barcode) = item, let text = barcode.payloadStringValue {
          dataScanner.stopScanning()
          found(text)
          return
        }
      }
    }
  }
}
