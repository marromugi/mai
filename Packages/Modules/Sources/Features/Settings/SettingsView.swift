import SwiftUI
internal import Typesetting

/// The app's settings in a sheet, closed by the button at the top trailing corner.
struct SettingsView: View {
  @AppStorage(StoredBodySetting.key) private var stored = StoredBodySetting(.standard)
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      SettingsForm(
        defaultSetting: Binding(get: { stored.setting }, set: { stored = StoredBodySetting($0) })
      )
      .navigationTitle("設定")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button(role: .close) { dismiss() }
        }
      }
    }
  }
}

/// iOS's grouped list of settings. Its 「フォント」 section steps `defaultSetting`, the body setting
/// a writing is set in until its own is adjusted, over a sample set in it.
struct SettingsForm: View {
  @Binding var defaultSetting: BodySetting

  var body: some View {
    Form {
      Section {
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
    }
  }

  static let sample = "朝の光が机に届くころ、書きかけの文章をもう一度読み返す。"

  private func points(_ value: CGFloat) -> String {
    Double(value).formatted(.number.precision(.fractionLength(0...1)))
  }
}

/// One value of a body setting, with what it reads as and a stepper that moves it a step at a time
/// within its range.
private struct SettingStepper: View {
  let title: LocalizedStringKey
  let adjustment: BodyAdjustment
  @Binding var setting: BodySetting
  let value: (BodySetting) -> String

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
    Stepper(
      value: Binding(
        get: { setting[adjustment] },
        set: {
          setting = setting.moving(adjustment, by: ($0 - setting[adjustment]) / adjustment.step)
        }
      ),
      in: adjustment.range,
      step: adjustment.step
    ) {
      LabeledContent(title, value: value(setting))
    }
  }
}

#Preview {
  SettingsView()
}
