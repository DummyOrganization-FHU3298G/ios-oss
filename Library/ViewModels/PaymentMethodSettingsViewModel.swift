import Foundation
import KsApi
import Prelude
import ReactiveSwift
import StripePaymentSheet

public protocol PaymentMethodSettingsViewModelInputs {
  func failedToAddNewCard()
  func didDelete(_ creditCard: UserCreditCards.CreditCard, visibleCellCount: Int)
  func editButtonTapped()
  func paymentMethodsFooterViewDidTapAddNewCardButton()
  func paymentSheetDidAdd(
    newCard card: PaymentSheetPaymentOptionsDisplayData,
    setupIntent: String
  )
  func shouldCancelPaymentSheetAppearance(state: Bool)
  func viewDidLoad()
}

public protocol PaymentMethodSettingsViewModelOutputs {
  var cancelAddNewCardLoadingState: Signal<Void, Never> { get }
  var editButtonIsEnabled: Signal<Bool, Never> { get }
  var editButtonTitle: Signal<String, Never> { get }
  var errorLoadingPaymentMethodsOrSetupIntent: Signal<String, Never> { get }
  var goToPaymentSheet: Signal<PaymentSheetSetupData, Never> { get }
  var paymentMethods: Signal<[UserCreditCards.CreditCard], Never> { get }
  var presentBanner: Signal<String, Never> { get }
  var reloadData: Signal<Void, Never> { get }
  var setStripePublishableKey: Signal<String, Never> { get }
  var showAlert: Signal<String, Never> { get }
  var tableViewIsEditing: Signal<Bool, Never> { get }
}

public protocol PaymentMethodsViewModelType {
  var inputs: PaymentMethodSettingsViewModelInputs { get }
  var outputs: PaymentMethodSettingsViewModelOutputs { get }
}

public final class PaymentMethodSettingsViewModel: PaymentMethodsViewModelType,
  PaymentMethodSettingsViewModelInputs, PaymentMethodSettingsViewModelOutputs {
  let stripeIntentService: StripeIntentServiceType

  public init(stripeIntentService: StripeIntentServiceType) {
    self.stripeIntentService = stripeIntentService

    self.reloadData = self.viewDidLoadProperty.signal

    let paymentMethodsEvent = Signal.merge(
      self.viewDidLoadProperty.signal,
      self.addNewCardSucceededProperty.signal.ignoreValues(),
      self.failedToAddNewCardProperty.signal
    )
    .switchMap { _ in
      AppEnvironment.current.apiService.fetchGraphUser(withStoredCards: true)
        .ksr_delay(AppEnvironment.current.apiDelayInterval, on: AppEnvironment.current.scheduler)
        .materialize()
    }

    let paymentSheetEnabled: Bool = true

    let deletePaymentMethodEvents = self.didDeleteCreditCardSignal
      .map(first)
      .switchMap { creditCard in
        AppEnvironment.current.apiService.deletePaymentMethod(input: .init(paymentSourceId: creditCard.id))
          .ksr_delay(AppEnvironment.current.apiDelayInterval, on: AppEnvironment.current.scheduler)
          .materialize()
      }

    let deletePaymentMethodEventsErrors = deletePaymentMethodEvents.errors()

    self.showAlert = deletePaymentMethodEventsErrors
      .ignoreValues()
      .map {
        Strings.Something_went_wrong_and_we_were_unable_to_remove_your_payment_method_please_try_again()
      }

    let initialPaymentMethodsValues = paymentMethodsEvent
      .values().map { $0.me.storedCards.storedCards }

    let deletePaymentMethodValues = deletePaymentMethodEvents.values()
      .map { $0.storedCards }

    let latestPaymentMethods = Signal.merge(
      initialPaymentMethodsValues,
      deletePaymentMethodValues
    )

    let newSetupIntentCards = self.newSetupIntentCreditCardProperty.signal.skipNil()
      .map { data -> PaymentSheetPaymentMethodCellData? in
        let (displayData, setupIntent) = data

        return (
          image: displayData.image,
          redactedCardNumber: displayData.label,
          clientSecret: setupIntent,
          isSelected: false,
          isEnabled: true
        )
      }
      .map { paymentMethodData -> String? in
        guard let selectedPaymentSheetPaymentMethodCardId = paymentMethodData?.clientSecret else {
          return nil
        }

        return selectedPaymentSheetPaymentMethodCardId
      }
      .skipNil()
      .map { setupIntent in
        CreatePaymentSourceSetupIntentInput.init(intentClientSecret: setupIntent, reuseable: true)
      }
      .switchMap { inputValue in
        AppEnvironment.current.apiService.addPaymentSheetPaymentSource(input: inputValue)
          .ksr_delay(AppEnvironment.current.apiDelayInterval, on: AppEnvironment.current.scheduler)
          .map { (envelope: CreatePaymentSourceEnvelope) in envelope.createPaymentSource }
          .materialize()
      }

    self.addNewCardSucceededProperty <~ newSetupIntentCards.values()
      .map { _ in Strings.Got_it_your_changes_have_been_saved() }

    self.paymentMethods = Signal.merge(
      initialPaymentMethodsValues,
      deletePaymentMethodEventsErrors
        .withLatest(from: latestPaymentMethods)
        .map(second)
    )

    let hasAtLeastOneCard = Signal.merge(
      self.paymentMethods
        .map { !$0.isEmpty },
      deletePaymentMethodValues
        .map { !$0.isEmpty },
      self.didDeleteCreditCardSignal.map(second)
        .map { $0 > 0 }
    )

    self.editButtonIsEnabled = Signal.merge(
      self.viewDidLoadProperty.signal.mapConst(false),
      hasAtLeastOneCard
    )
    .skipRepeats()

    self.presentBanner = self.addNewCardSucceededProperty.signal.skipNil()

    self.tableViewIsEditing = self.tableViewIsEditingProperty.signal

    self.editButtonTitle = self.tableViewIsEditing
      .map { $0 ? Strings.Done() : Strings.discovery_favorite_categories_buttons_edit() }

    let createSetupIntentEvent = self.didTapAddCardButtonProperty.signal
      .switchMap { SignalProducer(value: paymentSheetEnabled) }
      .filter(isTrue)
      .switchMap { _ -> SignalProducer<Signal<PaymentSheetSetupData, ErrorEnvelope>.Event, Never> in
        stripeIntentService.createSetupIntent(for: nil, context: .profileSettings)
          .ksr_debounce(.seconds(1), on: AppEnvironment.current.scheduler)
          .ksr_delay(AppEnvironment.current.apiDelayInterval, on: AppEnvironment.current.scheduler)
          .switchMap { envelope -> SignalProducer<PaymentSheetSetupData, ErrorEnvelope> in
            var configuration = PaymentSheet.Configuration()
            configuration.merchantDisplayName = Strings.general_accessibility_kickstarter()
            configuration.allowsDelayedPaymentMethods = true
            let data = PaymentSheetSetupData(
              clientSecret: envelope.clientSecret,
              configuration: configuration,
              paymentSheetType: .setupIntent
            )
            return SignalProducer(value: data)
          }
          .materialize()
      }

    self.cancelAddNewCardLoadingState = self.shouldCancelPaymentSheetAppearance.signal.filter(isTrue)
      .ignoreValues()

    self.goToPaymentSheet = createSetupIntentEvent.values()
      .withLatestFrom(self.shouldCancelPaymentSheetAppearance.signal)
      .map { data, shouldCancel -> PaymentSheetSetupData? in
        shouldCancel ? nil : data
      }
      .skipNil()

    let stopEditing = Signal.merge(
      self.editButtonIsEnabled.filter(isFalse),
      self.goToPaymentSheet.signal.ignoreValues().mapConst(false)
    )

    self.tableViewIsEditingProperty <~ Signal.merge(
      stopEditing,
      self.editButtonTappedSignal
        .withLatest(from: self.tableViewIsEditingProperty.signal)
        .map(second)
        .negate()
    )

    self.errorLoadingPaymentMethodsOrSetupIntent = Signal.merge(
      paymentMethodsEvent.errors(),
      createSetupIntentEvent.errors(),
      newSetupIntentCards.errors()
    )
    .map { $0.localizedDescription }

    self.shouldCancelPaymentSheetAppearance <~ Signal
      .merge(
        self.didTapAddCardButtonProperty.signal
          .ignoreValues()
          .mapConst(false),
        self.addNewCardSucceededProperty.signal
          .ignoreValues()
          .mapConst(true),
        self.errorLoadingPaymentMethodsOrSetupIntent.signal
          .ignoreValues()
          .mapConst(true)
      )

    self.setStripePublishableKey = self.viewDidLoadProperty.signal
      .map { _ in AppEnvironment.current.environmentType.stripePublishableKey }
  }

  // Stores the table view's editing state as it is affected by multiple signals
  private let tableViewIsEditingProperty = MutableProperty<Bool>(false)

  fileprivate let (didDeleteCreditCardSignal, didDeleteCreditCardObserver) =
    Signal<
      (UserCreditCards.CreditCard, Int),
      Never
    >.pipe()
  public func didDelete(_ creditCard: UserCreditCards.CreditCard, visibleCellCount: Int) {
    self.didDeleteCreditCardObserver.send(value: (creditCard, visibleCellCount))
  }

  fileprivate let (editButtonTappedSignal, editButtonTappedObserver) = Signal<(), Never>.pipe()
  public func editButtonTapped() {
    self.editButtonTappedObserver.send(value: ())
  }

  fileprivate let viewDidLoadProperty = MutableProperty(())
  public func viewDidLoad() {
    self.viewDidLoadProperty.value = ()
  }

  fileprivate let failedToAddNewCardProperty = MutableProperty(())
  public func failedToAddNewCard() {
    self.failedToAddNewCardProperty.value = ()
  }

  fileprivate let didTapAddCardButtonProperty = MutableProperty(())
  public func paymentMethodsFooterViewDidTapAddNewCardButton() {
    self.didTapAddCardButtonProperty.value = ()
  }

  fileprivate let addNewCardSucceededProperty = MutableProperty<String?>(nil)
  public func addNewCardSucceeded(with message: String) {
    self.addNewCardSucceededProperty.value = message
  }

  private let newSetupIntentCreditCardProperty =
    MutableProperty<(PaymentSheetPaymentOptionsDisplayData, String)?>(nil)
  public func paymentSheetDidAdd(
    newCard card: PaymentSheetPaymentOptionsDisplayData,
    setupIntent: String
  ) {
    self.newSetupIntentCreditCardProperty.value = (card, setupIntent)
  }

  private let shouldCancelPaymentSheetAppearance = MutableProperty<Bool>(false)
  public func shouldCancelPaymentSheetAppearance(state: Bool) {
    self.shouldCancelPaymentSheetAppearance.value = state
  }

  public let cancelAddNewCardLoadingState: Signal<Void, Never>
  public let editButtonIsEnabled: Signal<Bool, Never>
  public let editButtonTitle: Signal<String, Never>
  public let errorLoadingPaymentMethodsOrSetupIntent: Signal<String, Never>
  public let goToPaymentSheet: Signal<PaymentSheetSetupData, Never>
  public let paymentMethods: Signal<[UserCreditCards.CreditCard], Never>
  public let presentBanner: Signal<String, Never>
  public let reloadData: Signal<Void, Never>
  public let setStripePublishableKey: Signal<String, Never>
  public let showAlert: Signal<String, Never>
  public let tableViewIsEditing: Signal<Bool, Never>

  public var inputs: PaymentMethodSettingsViewModelInputs { return self }
  public var outputs: PaymentMethodSettingsViewModelOutputs { return self }
}
