import SwiftUI
import UIKit

/// What takes the writing page's photos: the device's camera, or a stand-in that hands back a photo
/// of its own.
struct Camera {
  /// Whether a photo can be taken here. The simulator has no camera.
  let isAvailable: Bool
  /// The full-screen view that takes one photo and hands it to `taken`, or calls `cancelled`.
  let screen: (_ taken: @escaping (UIImage) -> Void, _ cancelled: @escaping () -> Void) -> AnyView
}

extension Camera {
  static let device = Camera(
    isAvailable: UIImagePickerController.isSourceTypeAvailable(.camera)
  ) { taken, cancelled in
    AnyView(CameraPicker(taken: taken, cancelled: cancelled).ignoresSafeArea())
  }
}

/// The system's camera screen.
struct CameraPicker: UIViewControllerRepresentable {
  let taken: (UIImage) -> Void
  let cancelled: () -> Void

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ picker: UIImagePickerController, context: Context) {
    context.coordinator.picker = self
  }

  func makeCoordinator() -> Coordinator { Coordinator(picker: self) }

  final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate
  {
    var picker: CameraPicker

    init(picker: CameraPicker) {
      self.picker = picker
    }

    func imagePickerController(
      _ controller: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      guard let photo = info[.originalImage] as? UIImage else {
        preconditionFailure("The camera finished with no photo, though it takes only photos.")
      }
      picker.taken(photo)
    }

    func imagePickerControllerDidCancel(_ controller: UIImagePickerController) {
      picker.cancelled()
    }
  }
}
