import SwiftUI
import UIKit
internal import Typesetting

extension View {
  /// Steps `setting` by the typesetting gestures over this view, with a light haptic on each
  /// step: a vertical pinch moves the line height, a horizontal pinch the tracking, and a
  /// one-finger drag up or down the base.
  func bodySettingGestures(_ setting: Binding<BodySetting>) -> some View {
    gesture(BodyPinchReader(setting: setting))
      .gesture(BodyDragReader(setting: setting))
  }
}

/// One recognizer's gesture in progress, and the haptic it gives on each step.
private final class GestureRun<Gesture> {
  var gesture: Gesture?
  private var feedback: UIImpactFeedbackGenerator?

  func begin(_ gesture: Gesture?, in view: UIView?) {
    self.gesture = gesture
    feedback = nil
    guard gesture != nil, let view else { return }
    feedback = UIImpactFeedbackGenerator(style: .light, view: view)
    feedback?.prepare()
  }

  func end() {
    gesture = nil
    feedback = nil
  }

  /// Writes the gesture's value to `setting` when it is a step away, with a haptic where the
  /// finger is. The other values stay as `setting` holds them now.
  func step(_ setting: Binding<BodySetting>, to adjusted: SteppedAdjustment, at location: CGPoint) {
    let current = setting.wrappedValue
    let next = current.taking(adjusted.adjustment, from: adjusted.setting)
    guard next != current else { return }
    setting.wrappedValue = next
    feedback?.impactOccurred(at: location)
  }
}

/// `MagnifyGesture` gives no finger positions, so the two touches are read from UIKit's
/// recognizer.
private struct BodyPinchReader: UIGestureRecognizerRepresentable {
  @Binding var setting: BodySetting

  func makeCoordinator(converter: CoordinateSpaceConverter) -> GestureRun<BodyPinch> {
    GestureRun()
  }

  func makeUIGestureRecognizer(context: Context) -> TouchDownPinchRecognizer {
    TouchDownPinchRecognizer()
  }

  func handleUIGestureRecognizerAction(_ recognizer: TouchDownPinchRecognizer, context: Context) {
    let run = context.coordinator
    switch recognizer.state {
    case .began:
      let pinch = recognizer.touchDown.flatMap { BodyPinch($0.0, $0.1, from: setting) }
      run.begin(pinch, in: recognizer.view)
      follow(recognizer, run)
    case .changed:
      follow(recognizer, run)
    default:
      run.end()
    }
  }

  private func follow(_ recognizer: TouchDownPinchRecognizer, _ run: GestureRun<BodyPinch>) {
    guard var pinch = run.gesture else { return }
    // Once either finger lifts, the pinch is over: a finger landing again is a new touch.
    guard let (first, second) = recognizer.fingers else {
      run.end()
      return
    }
    pinch.move(first, second)
    run.gesture = pinch
    run.step($setting, to: pinch.adjustment, at: recognizer.location(in: recognizer.view))
  }
}

/// A pinch that follows its own two fingers from the moment the second one lands. UIKit begins a
/// pinch only after the fingers have moved, and the axis and the steps count from that moment.
private final class TouchDownPinchRecognizer: UIPinchGestureRecognizer {
  /// A touch object stays the same for its finger until the finger lifts.
  private var touchObjects: [UITouch] = []
  private var lifted = false
  private(set) var touchDown: (CGPoint, CGPoint)?

  /// The two fingers, first to land first; nil once either has lifted.
  var fingers: (CGPoint, CGPoint)? {
    guard touchObjects.count == 2, !lifted else { return nil }
    return (touchObjects[0].location(in: view), touchObjects[1].location(in: view))
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesBegan(touches, with: event)
    for touch in touches where touchObjects.count < 2 {
      touchObjects.append(touch)
    }
    if touchDown == nil { touchDown = fingers }
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesEnded(touches, with: event)
    if !touches.isDisjoint(with: touchObjects) { lifted = true }
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesCancelled(touches, with: event)
    if !touches.isDisjoint(with: touchObjects) { lifted = true }
  }

  override func reset() {
    super.reset()
    touchObjects = []
    lifted = false
    touchDown = nil
  }
}

private struct BodyDragReader: UIGestureRecognizerRepresentable {
  @Binding var setting: BodySetting

  func makeCoordinator(converter: CoordinateSpaceConverter) -> GestureRun<BodyDrag> {
    GestureRun()
  }

  func makeUIGestureRecognizer(context: Context) -> TouchDownPanRecognizer {
    let recognizer = TouchDownPanRecognizer()
    recognizer.maximumNumberOfTouches = 1
    return recognizer
  }

  func handleUIGestureRecognizerAction(_ recognizer: TouchDownPanRecognizer, context: Context) {
    let run = context.coordinator
    switch recognizer.state {
    case .began:
      let drag = recognizer.translation.flatMap { BodyDrag(translation: $0, from: setting) }
      run.begin(drag, in: recognizer.view)
      follow(recognizer, run)
    case .changed:
      follow(recognizer, run)
    default:
      run.end()
    }
  }

  private func follow(_ recognizer: TouchDownPanRecognizer, _ run: GestureRun<BodyDrag>) {
    guard var drag = run.gesture, let translation = recognizer.translation else { return }
    drag.move(translation: translation)
    run.gesture = drag
    run.step($setting, to: drag.adjustment, at: recognizer.location(in: recognizer.view))
  }
}

/// A pan that keeps where its finger touched down. UIKit's own translation starts where it
/// recognized the pan, after the finger has moved, and the axis and the steps count from
/// touch-down.
private final class TouchDownPanRecognizer: UIPanGestureRecognizer {
  private var touchDown: CGPoint?

  /// How far the finger has moved since it touched down.
  var translation: CGPoint? {
    guard let touchDown else { return nil }
    let location = location(in: view)
    return CGPoint(x: location.x - touchDown.x, y: location.y - touchDown.y)
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesBegan(touches, with: event)
    if touchDown == nil { touchDown = touches.first?.location(in: view) }
  }

  override func reset() {
    super.reset()
    touchDown = nil
  }
}

struct BodySettingGesturesPreview: View {
  @State private var setting = BodySetting.standard

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("base \(setting.base)  行送り \(setting.lineHeight)  字間 \(setting.tracking)")
        .textStyle(.meta)
      Text(body: "縦にピンチで行間、横にピンチで字間、上下にドラッグで文字の大きさが変わる。")
        .textStyle(.body)
        .environment(\.bodySetting, setting)
      Spacer()
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .contentShape(.rect)
    .bodySettingGestures($setting)
  }
}

#Preview("Body setting gestures") {
  BodySettingGesturesPreview()
}
