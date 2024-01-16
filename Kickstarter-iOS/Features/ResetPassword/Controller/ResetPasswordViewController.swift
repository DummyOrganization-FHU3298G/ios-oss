import Library
import Prelude
import Prelude_UIKit
import ReactiveExtensions
import ReactiveSwift
import UIKit

internal final class ResetPasswordViewController: UIViewController {
  @IBOutlet private var emailTextFieldBackgroundView: UIView!
  @IBOutlet private var emailTextField: UITextField!
  @IBOutlet private var resetPasswordButton: UIButton!
  @IBOutlet private var rootStackView: UIStackView!

  fileprivate let viewModel: ResetPasswordViewModelType = ResetPasswordViewModel()

  internal static func configuredWith(email: String?) -> ResetPasswordViewController {
    let vc = Storyboard.Login.instantiate(ResetPasswordViewController.self)
    if let email = email {
      vc.viewModel.inputs.emailChanged(email)
    }
    return vc
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    self.viewModel.inputs.viewDidLoad()
  }

  override func bindStyles() {
    if featureDarkModeEnabled() {
      _ = self.navigationController?.navigationBar.tintColor = adaptiveColor(.iconPrimary)
    }

    _ = self |> resetPasswordControllerStyle
    _ = self.emailTextField |> featureDarkModeEnabled() ? adaptiveEmailFieldStyle : emailFieldStyle
    _ = self.emailTextFieldBackgroundView
      |> cardStyle()
      |> \.backgroundColor .~ .clear
    _ = self.resetPasswordButton
      |> featureDarkModeEnabled() ? adaptivePrimaryButtonStyle : resetPasswordButtonStyle
      |> UIButton.lens.title(for: .normal) %~ { _ in Strings.forgot_password_buttons_reset_my_password() }
    _ = self.rootStackView |> loginRootStackViewStyle
  }

  override func bindViewModel() {
    super.bindViewModel()

    self.emailTextField.rac.becomeFirstResponder = self.viewModel.outputs.emailTextFieldBecomeFirstResponder

    self.viewModel.outputs.setEmailInitial
      .observeForControllerAction()
      .observeValues { [weak self] email in
        self?.emailTextField.text = email
      }

    self.resetPasswordButton.rac.enabled = self.viewModel.outputs.formIsValid

    self.viewModel.outputs.showResetSuccess
      .observeForControllerAction()
      .observeValues { [weak self] message in
        self?.present(UIAlertController.alert(
          message: message,
          handler: { _ in
            self?.viewModel.inputs.confirmResetButtonPressed()
          }
        ), animated: true, completion: nil)
      }

    self.viewModel.outputs.returnToLogin
      .observeForControllerAction()
      .observeValues { [weak self] _ in
        _ = self?.navigationController?.popViewController(animated: true)
      }

    self.viewModel.outputs.showError
      .observeForControllerAction()
      .observeValues { [weak self] message in
        self?.present(UIAlertController.genericError(message), animated: true, completion: nil)
      }
  }

  @IBAction
  internal func emailTextFieldEditingChanged(_ textfield: UITextField) {
    self.viewModel.inputs.emailChanged(textfield.text)
  }

  @IBAction
  internal func resetPasswordPressed(_: UIButton) {
    self.emailTextField.resignFirstResponder()
    self.viewModel.inputs.resetButtonPressed()
  }
}
