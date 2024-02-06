import Foundation
@testable import Kickstarter_Framework
import Library
import SnapshotTesting

internal final class SignupViewControllerTests: TestCase {
  override func setUp() {
    super.setUp()
    AppEnvironment.pushEnvironment(mainBundle: Bundle.framework)
  }

  func testView() {
    let devices = [Device.phone4_7inch, Device.pad, Device.phone5_8inch]
    orthogonalCombos(Language.allLanguages, devices).forEach { language, device in
      withEnvironment(language: language) {
        let controller = SignupViewController.instantiate()
        let (parent, _) = traitControllers(device: device, orientation: .portrait, child: controller)

        self.scheduler.run()

        assertSnapshot(
          matching: parent.view,
          as: .image(perceptualPrecision: 0.98),
          named: "lang_\(language)_device_\(device)"
        )
      }
    }
  }

  override func tearDown() {
    AppEnvironment.popEnvironment()
    super.tearDown()
  }
}
