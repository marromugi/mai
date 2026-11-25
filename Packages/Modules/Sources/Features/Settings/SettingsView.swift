import SwiftUI
internal import Typesetting

/// The app's settings in a sheet, closed by the button at the top trailing corner.
struct SettingsView: View {
  let fonts: FontLibrary
  @AppStorage(StoredBodySetting.key) private var stored = StoredBodySetting.standard
  @AppStorage(StoredFontStack.key) private var fontStack = StoredFontStack.standard
  @AppStorage(ColorTheme.key) private var theme = ColorTheme.system
  @Environment(\.dismiss) private var dismiss
  @Environment(\.account) private var account

  var body: some View {
    NavigationStack {
      SettingsForm(
        defaultSetting: Binding(get: { stored.setting }, set: { stored = StoredBodySetting($0) }),
        fontStack: Binding(get: { fontStack.stack }, set: { fontStack = StoredFontStack($0) }),
        fonts: fonts,
        theme: $theme
      )
      .environment(\.fontFamilies, fontStack.stack.families(from: fonts.available))
      .navigationTitle("設定")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button(role: .close) { dismiss() }
        }
      }
    }
    .sheet(
      isPresented: Binding(
        get: { account?.recoveryKeyToShow != nil },
        set: { if !$0 { account?.recoveryKeyWrittenDown() } })
    ) {
      if let recoveryKey = account?.recoveryKeyToShow {
        NavigationStack {
          RecoveryKeyView(recoveryKey: recoveryKey) { account?.recoveryKeyWrittenDown() }
        }
      }
    }
    .alert(
      "同期のアカウント",
      isPresented: Binding(
        get: { account?.problem != nil }, set: { if !$0 { account?.problem = nil } })
    ) {
    } message: {
      Text(verbatim: account?.problem ?? "")
    }
  }
}

/// iOS's grouped list of settings. Its 「フォント」 section leads to `fontStack`, the families text
/// is set in, and steps `defaultSetting`, the body setting a writing is set in until its own is
/// adjusted, over a sample set in both; its 「カラーテーマ」 section chooses `theme`; its 「同期」
/// section opens the plans, followed, where there is a server, by the account's (`AccountRows`).
struct SettingsForm: View {
  @Binding var defaultSetting: BodySetting
  @Binding var fontStack: FontStack
  let fonts: FontLibrary
  @Binding var theme: ColorTheme
  @Environment(\.account) private var account
  @Environment(\.writingSync) private var sync

  var body: some View {
    Form {
      Section {
        NavigationLink {
          FontStackView(stack: $fontStack, fonts: fonts)
        } label: {
          LabeledContent(
            "書体",
            value: fontStack.families(from: fonts.available).map(\.title).joined(separator: " → "))
        }
        SettingStepper("文字の大きさ", .base, setting: $defaultSetting) {
          "\(points(TypeScale(factor: 1, body: $0).size(.body))) pt"
        }
        SettingStepper("行送り", .lineHeight, setting: $defaultSetting) {
          "\(points(TypeScale(factor: 1, body: $0).lineHeight(.body))) pt"
        }
        SettingStepper("字間", .tracking, setting: $defaultSetting) {
          "\(($0.tracking / 10).formatted())%"
        }
        Text(body: Self.sample)
          .textStyle(.body)
          .environment(\.bodySetting, defaultSetting)
          .padding(.vertical, 4)
        Button("標準に戻す") { defaultSetting = .standard }
          .disabled(defaultSetting == .standard)
      } header: {
        Text("フォント")
      } footer: {
        Text("原稿はそれぞれ「組版を調整」で変えるまで、この設定で組まれます。")
      }
      Section("カラーテーマ") {
        Picker("カラーテーマ", selection: $theme) {
          ForEach(ColorTheme.allCases) { Text($0.title) }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      }
      Section {
        NavigationLink("同期のプラン") { PlansView() }
      } header: {
        Text("同期")
      } footer: {
        Text(Self.syncFooter(account?.phase))
      }
      if let account {
        AccountSection(account: account, sync: sync)
        if account.phase == .signedIn {
          ReadModeSection(account: account)
        }
      }
    }
  }

  /// Where the writings are kept, as the 「同期」 section says it for the account at `phase`.
  static func syncFooter(_ phase: AccountPhase?) -> LocalizedStringKey {
    phase == .signedIn
      ? "文書はこの端末に置き、暗号化して、サインインした端末どうしでそろえます。"
      : "文書はこの端末の中に置かれます。ほかの端末とそろえるには、プランに入ります。"
  }

  static let sample = "朝の光が机に届くころ、書きかけの文章をもう一度読み返す。"

  private func points(_ value: CGFloat) -> String {
    Double(value).formatted(.number.precision(.fractionLength(0...1)))
  }
}

/// One value of a body setting, with what it reads as and a stepper that moves it a step at a time
/// within its range. At accessibility sizes the stepper goes under the title and value, so neither
/// breaks mid-word.
private struct SettingStepper: View {
  let title: LocalizedStringKey
  let adjustment: BodyAdjustment
  @Binding var setting: BodySetting
  let value: (BodySetting) -> String
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  init(
    _ title: LocalizedStringKey, _ adjustment: BodyAdjustment, setting: Binding<BodySetting>,
    value: @escaping (BodySetting) -> String
  ) {
    self.title = title
    self.adjustment = adjustment
    _setting = setting
    self.value = value
  }

  var body: some View {
    if dynamicTypeSize.isAccessibilitySize {
      VStack(alignment: .leading) {
        // Read once, as the stepper's label.
        label.accessibilityHidden(true)
        stepper { label }.labelsHidden()
      }
    } else {
      stepper { label }
    }
  }

  private var label: some View {
    LabeledContent(title, value: value(setting))
  }

  private func stepper(_ label: () -> some View) -> some View {
    Stepper(
      value: Binding(
        get: { setting[adjustment] },
        set: { setting = setting.moving(adjustment, to: $0) }
      ),
      in: adjustment.range,
      step: adjustment.step,
      label: label)
  }
}

#Preview {
  SettingsView(fonts: FontLibrary(server: nil))
}
