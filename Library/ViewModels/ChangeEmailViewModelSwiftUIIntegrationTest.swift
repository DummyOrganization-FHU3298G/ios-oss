import Combine
import KsApi
import Prelude
import UIKit

public final class ChangeEmailViewModelSwiftUIIntegrationTest: ObservableObject {
  private var cancellables = Set<AnyCancellable>()

  /// Outputs
  @Published public var hideVerifyView = false
  @Published public var verifyEmailButtonTitle = ""
  @Published public var hideMessageLabel = true
  @Published public var warningMessageWithAlert = ("", false)

  /// Inputs
  public var saveButtonEnabled: AnyPublisher<Bool, Never>
  public var bannerMessage: PassthroughSubject<MessageBannerViewViewModel, Never> = .init()
  public var retrievedEmailText: PassthroughSubject<String, Never> = .init()
  public var newEmailText: PassthroughSubject<String, Never> = .init()
  public var currentPasswordText: PassthroughSubject<String, Never> = .init()
  public var saveTriggered: PassthroughSubject<Bool, Never> = .init()
  public var resetEditableText: PassthroughSubject<Bool, Never> = .init()
  private var viewDidLoadProperty: PassthroughSubject<Void, Never> = .init()
  private var updateEmailAndPasswordProperty: PassthroughSubject<(String, String), Never> = .init()
  /// Outputs
  public var didFailToSendVerificationEmail: PassthroughSubject<String, Never> = .init()
  public var didSendVerificationEmail: PassthroughSubject<Void, Never> = .init()
  public var emailText: PassthroughSubject<String, Never> = .init()
  public var messageLabelViewHidden: PassthroughSubject<Bool, Never> = .init()
  public var resendVerificationEmailViewIsHidden: PassthroughSubject<Bool, Never> = .init()
  public var unverifiedEmailLabelHidden: PassthroughSubject<Bool, Never> = .init()
  public var verificationEmailButtonTitle: PassthroughSubject<String, Never> = .init()
  public var warningMessageLabelHidden: PassthroughSubject<Bool, Never> = .init()
  public var resendVerificationEmailButtonProperty: PassthroughSubject<Void, Never> = .init()

  /// Subscribers
  public init() {
    let changeEmailEvent = self.updateEmailAndPasswordProperty
      .map(ChangeEmailInput.init(email:currentPassword:))
      .compactMap { input in
        AppEnvironment.current.apiService.changeEmail(input: input)
          .map { _ in input.email }
          // FIXME: Ideally we're going to use - `AppEnvironment.current.apiDelayInterval` but that needs a refactoring out of `DispatchTimeInterval` to `TimeIntveral`
          .debounce(for: .seconds(0.5), scheduler: DispatchQueue.global())
          .receive(on: DispatchQueue.global())
      }
      .eraseToAnyPublisher()
      .share()

    let userEmailEvent = self.viewDidLoadProperty
      .flatMap { _ in
        AppEnvironment.current
          .apiService
          .fetchGraphUser(withStoredCards: false)
          // FIXME: Ideally we're going to use - `AppEnvironment.current.apiDelayInterval` but that needs a refactoring out of `DispatchTimeInterval` to `TimeIntveral`
          .debounce(for: .seconds(0.5), scheduler: DispatchQueue.global())
          .receive(on: DispatchQueue.global())
      }
      .eraseToAnyPublisher()
      .share()

    let resendEmailVerificationEvent = self.resendVerificationEmailButtonProperty
      .flatMap { _ in
        AppEnvironment.current.apiService.sendVerificationEmail(input: EmptyInput())
      }

    let isEmailVerified = userEmailEvent
      .compactMap { envelope in
        envelope.me.isEmailVerified
      }
      .replaceError(with: false)
      .share()

    let isEmailDeliverable = userEmailEvent
      .compactMap { envelope in
        envelope.me.isDeliverable
      }
      .replaceError(with: false)
      .share()

    let emailVerifiedAndDeliverable = Publishers.CombineLatest(isEmailVerified, isEmailDeliverable)
      .map { isEmailVerified, isEmailDeliverable in
        isEmailVerified && isEmailDeliverable
      }
      .setFailureType(to: Never.self)
      .eraseToAnyPublisher()

    self.saveButtonEnabled = Publishers
      .CombineLatest3(self.retrievedEmailText, self.newEmailText, self.currentPasswordText)
      .removeDuplicates(by: ==)
      .map(shouldEnableSaveButton(email:newEmail:password:))
      .eraseToAnyPublisher()

    resendEmailVerificationEvent
      .sink(receiveCompletion: { [weak self] completion in
        switch completion {
        case .finished:
          break
        case let .failure(error):
          self?.didFailToSendVerificationEmail.send(error.localizedDescription)
        }
      }, receiveValue: { [weak self] _ in
        self?.didSendVerificationEmail.send(())
      })
      .store(in: &self.cancellables)

    Publishers.Merge(
      changeEmailEvent.flatMap { $0 },
      userEmailEvent.map { $0.me.email ?? "" }
    )
    .sink(receiveCompletion: { _ in
      // Error/completion results in nothing happening.
    }, receiveValue: { [weak self] text in
      self?.emailText.send(text)
    })
    .store(in: &self.cancellables)

    Publishers.Merge(
      self.viewDidLoadProperty.map { _ in true },
      emailVerifiedAndDeliverable
    )
    .removeDuplicates()
    .sink(receiveCompletion: { _ in
      // Error/completion results in nothing happening.
    }, receiveValue: { [weak self] flag in
      self?.resendVerificationEmailViewIsHidden.send(flag)
    })
    .store(in: &self.cancellables)

    self.viewDidLoadProperty
      .sink(receiveValue: { [weak self] _ in
        guard let user = AppEnvironment.current.currentUser else {
          self?.verificationEmailButtonTitle.send("")

          return
        }

        let verificationEmailButtonText = user.isCreator ? Strings.Resend_verification_email() : Strings
          .Send_verfication_email()

        self?.verificationEmailButtonTitle.send(verificationEmailButtonText)
      })
      .store(in: &self.cancellables)

    Publishers
      .CombineLatest(isEmailVerified, isEmailDeliverable)
      .sink(receiveValue: { [weak self] isEmailVerified, isEmailDeliverable in
        if !isEmailVerified {
          self?.unverifiedEmailLabelHidden.send(isEmailDeliverable)
        } else {
          self?.unverifiedEmailLabelHidden.send(isEmailVerified)
        }
      })
      .store(in: &self.cancellables)

    _ = isEmailDeliverable
      .map { [weak self] flag in
        self?.warningMessageLabelHidden.send(flag)
      }

    Publishers.Merge(self.unverifiedEmailLabelHidden, self.warningMessageLabelHidden)
      .filter(isFalse)
      .eraseToAnyPublisher()
      .sink(receiveValue: { [weak self] flag in
        self?.messageLabelViewHidden.send(flag)
      })
      .store(in: &self.cancellables)

    // MARK: Reactive Subscribers to Combine Publishers

    changeEmailEvent
      .sink(receiveCompletion: { [weak self] completed in
        switch completed {
        case .finished:
          break
        case let .failure(errorValue):
          let messageBannerViewViewModel = MessageBannerViewViewModel((
            type: .error,
            message: errorValue.localizedDescription
          ))

          self?.saveTriggered.send(false)
          self?.resetEditableText.send(true)
          self?.bannerMessage.send(messageBannerViewViewModel)
        }
      }, receiveValue: { [weak self] _ in
        let messageBannerViewViewModel = MessageBannerViewViewModel((
          type: .success,
          message: Strings.Got_it_your_changes_have_been_saved()
        ))

        self?.saveTriggered.send(false)
        self?.resetEditableText.send(true)
        self?.bannerMessage.send(messageBannerViewViewModel)
      })
      .store(in: &self.cancellables)

    Publishers
      .CombineLatest4(self.saveButtonEnabled, self.saveTriggered, self.newEmailText, self.currentPasswordText)
      .filter { enabledValue, triggeredValue, _, _ in
        enabledValue && triggeredValue
      }
      .sink(receiveValue: { [weak self] _, _, newEmailTextValue, newPasswordTextValue in
        self?.updateEmail(newEmail: newEmailTextValue, currentPassword: newPasswordTextValue)
      })
      .store(in: &self.cancellables)

    self.resendVerificationEmailViewIsHidden
      .receive(on: DispatchQueue.main)
      .sink(receiveValue: { [weak self] isHidden in
        self?.hideVerifyView = isHidden
      })
      .store(in: &self.cancellables)

    self.didSendVerificationEmail
      .receive(on: DispatchQueue.main)
      .sink(receiveValue: { [weak self] _ in
        let messageBannerViewViewModel = MessageBannerViewViewModel((
          type: .success,
          message: Strings.Verification_email_sent()
        ))

        self?.bannerMessage.send(messageBannerViewViewModel)
      })
      .store(in: &self.cancellables)

    self.didFailToSendVerificationEmail
      .receive(on: DispatchQueue.main)
      .sink(receiveValue: { [weak self] message in
        let messageBannerViewViewModel = MessageBannerViewViewModel((
          type: .error,
          message: message
        ))

        self?.bannerMessage.send(messageBannerViewViewModel)
      })
      .store(in: &self.cancellables)

    self.emailText
      .receive(on: DispatchQueue.main)
      .sink(receiveValue: { [weak self] emailText in
        self?.retrievedEmailText.send(emailText)
      })
      .store(in: &self.cancellables)

    self.verificationEmailButtonTitle
      .receive(on: DispatchQueue.main)
      .sink(receiveValue: { [weak self] titleText in
        self?.verifyEmailButtonTitle = titleText
      })
      .store(in: &self.cancellables)

    self.messageLabelViewHidden
      .receive(on: DispatchQueue.main)
      .sink(receiveValue: { [weak self] isHidden in
        self?.hideMessageLabel = isHidden
      })
      .store(in: &self.cancellables)

    self.unverifiedEmailLabelHidden
      .receive(on: DispatchQueue.main)
      .sink(receiveValue: { [weak self] isHidden in
        guard !isHidden else { return }

        self?.warningMessageWithAlert = (Strings.Email_unverified(), false)
      })
      .store(in: &self.cancellables)

    self.warningMessageLabelHidden
      .receive(on: DispatchQueue.main)
      .sink(receiveValue: { [weak self] isHidden in
        guard !isHidden else { return }

        self?.warningMessageWithAlert = (Strings.We_ve_been_unable_to_send_email(), true)
      })
      .store(in: &self.cancellables)
  }

  /// Input functions
  public func updateEmail(newEmail: String, currentPassword: String) {
    let emailAndPassword = (newEmail, currentPassword)

    self.updateEmailAndPasswordProperty.send(emailAndPassword)
  }

  public func resendVerificationEmailButtonTapped() {
    self.resendVerificationEmailButtonProperty.send(())
  }

  public func viewDidLoad() {
    self.viewDidLoadProperty.send(())
  }
}

/// Helper functions
private func shouldEnableSaveButton(email: String?, newEmail: String?, password: String?) -> Bool {
  guard
    let newEmail = newEmail,
    isValidEmail(newEmail),
    email != newEmail,
    password != nil

  else { return false }

  return ![newEmail, password]
    .compact()
    .map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    .contains(false)
}
