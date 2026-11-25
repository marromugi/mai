import SwiftUI
import Testing
import Typesetting
import UIKit

@testable import Features

@MainActor
struct WritingCameraTests {
  /// Once the camera is tapped its screen is asked for, its photo reaches the page's handler, and
  /// the page closes the camera.
  @Test func aPhotoTakenReachesTheHandler() async throws {
    let photo = Camera.photo(.red)
    let takingPhoto = Flag()
    var shown = 0
    var taken: [UIImage] = []
    let page = HostedPage(
      screen(takingPhoto, camera: .standIn(taking: photo) { shown += 1 }) { taken.append($0) })
    try await page.settle { !takingPhoto.on }
    #expect(shown == 1)
    #expect(taken.count == 1)
    #expect(taken.first === photo)
    #expect(!takingPhoto.on)
  }

  /// Cancelled, the camera hands nothing on, and the page closes it.
  @Test func aCancelledCameraHandsNothingOn() async throws {
    let takingPhoto = Flag()
    var shown = 0
    var taken: [UIImage] = []
    let page = HostedPage(
      screen(takingPhoto, camera: .standIn(taking: nil) { shown += 1 }) { taken.append($0) })
    try await page.settle { !takingPhoto.on }
    #expect(shown == 1)
    #expect(taken.isEmpty)
    #expect(!takingPhoto.on)
  }

  /// The system camera is set to take photos, and reports to the handlers it was last given.
  @Test func theSystemCameraReportsToItsLatestHandlers() throws {
    let photo = Camera.photo(.green)
    var taken: [UIImage] = []
    let page = HostedPage(
      CameraPicker(taken: { _ in Issue.record("An old handler got the photo.") }, cancelled: {}))
    page.show(CameraPicker(taken: { taken.append($0) }, cancelled: {}))
    let controller = try #require(page.child(UIImagePickerController.self))
    #expect(controller.sourceType == .camera)
    let delegate = try #require(controller.delegate as? CameraPicker.Coordinator)
    delegate.imagePickerController(
      controller, didFinishPickingMediaWithInfo: [.originalImage: photo])
    #expect(taken.count == 1)
    #expect(taken.first === photo)
  }

  /// The system camera hands on the photo it took, or its cancel.
  @Test func theSystemCameraHandsOnWhatItGot() {
    let photo = Camera.photo(.blue)
    var taken: [UIImage] = []
    var cancels = 0
    let picker = CameraPicker(taken: { taken.append($0) }, cancelled: { cancels += 1 })
    let coordinator = picker.makeCoordinator()
    let controller = UIImagePickerController()
    coordinator.imagePickerController(
      controller, didFinishPickingMediaWithInfo: [.originalImage: photo])
    coordinator.imagePickerControllerDidCancel(controller)
    #expect(taken.count == 1)
    #expect(taken.first === photo)
    #expect(cancels == 1)
  }
}

/// Whether the page's camera is open, starting just after it was tapped.
private final class Flag {
  var on = true
}

private func screen(
  _ takingPhoto: Flag, camera: Camera, photoTaken: @escaping (UIImage) -> Void
) -> WritingScreen {
  WritingScreen(
    writing: Writing(title: "間合いの調整", body: Writing.sampleBody), others: [], open: { _ in },
    edit: { _ in },
    photos: [],
    setting: .constant(.standard),
    typesetting: .constant(false),
    takingPhoto: Binding {
      takingPhoto.on
    } set: {
      takingPhoto.on = $0
    },
    camera: camera,
    photoTaken: photoTaken)
}
