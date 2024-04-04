import Foundation
import KsApi
import PassKit
import Prelude
import ReactiveSwift
import Stripe

public struct PostCampaignCheckoutData: Equatable {
  public let project: Project
  public let baseReward: Reward
  public let rewards: [Reward]
  public let selectedQuantities: SelectedRewardQuantities
  public let bonusAmount: Double?
  public let total: Double
  public let shipping: PledgeShippingSummaryViewData?
  public let refTag: RefTag?
  public let context: PledgeViewContext
}

public struct PostCampaignPaymentAuthorizationData: Equatable {
  public let project: Project
  public let hasNoReward: Bool
  public let subtotal: Double
  public let bonus: Double
  public let shipping: Double
  public let total: Double
  public let merchantIdentifier: String
  public let paymentIntent: String
}

public struct PaymentSourceValidation {
  public let paymentIntentClientSecret: String
  public let selectedCardStripeCardId: String?
  public let requiresConfirmation: Bool
}

public protocol PostCampaignCheckoutViewModelInputs {
  func checkoutTerminated()
  func configure(with data: PostCampaignCheckoutData)
  func confirmPaymentSuccessful(clientSecret: String)
  func creditCardSelected(source: PaymentSourceSelected, paymentMethodId: String, isNewPaymentMethod: Bool)
  func goToLoginSignupTapped()
  func pledgeDisclaimerViewDidTapLearnMore()
  func submitButtonTapped()
  func termsOfUseTapped(with: HelpType)
  func userSessionStarted()
  func viewDidLoad()
  func applePayButtonTapped()
  func applePayContextDidCreatePayment(params: ApplePayParams)
  func applePayContextDidComplete()
}

public protocol PostCampaignCheckoutViewModelOutputs {
  var configurePaymentMethodsViewControllerWithValue: Signal<PledgePaymentMethodsValue, Never> { get }
  var configurePledgeRewardsSummaryViewWithData: Signal<
    (PostCampaignRewardsSummaryViewData, Double?, PledgeSummaryViewData),
    Never
  > { get }
  var configurePledgeViewCTAContainerView: Signal<PledgeViewCTAContainerViewData, Never> { get }
  var configureStripeIntegration: Signal<StripeConfigurationData, Never> { get }
  var goToLoginSignup: Signal<(LoginIntent, Project, Reward?), Never> { get }
  var paymentMethodsViewHidden: Signal<Bool, Never> { get }
  var processingViewIsHidden: Signal<Bool, Never> { get }
  var showErrorBannerWithMessage: Signal<String, Never> { get }
  var showWebHelp: Signal<HelpType, Never> { get }
  var validateCheckoutSuccess: Signal<PaymentSourceValidation, Never> { get }
  var goToApplePayPaymentAuthorization: Signal<PostCampaignPaymentAuthorizationData, Never> { get }
  var checkoutComplete: Signal<ThanksPageData, Never> { get }
  var checkoutError: Signal<ErrorEnvelope, Never> { get }
}

public protocol PostCampaignCheckoutViewModelType {
  var inputs: PostCampaignCheckoutViewModelInputs { get }
  var outputs: PostCampaignCheckoutViewModelOutputs { get }
}

public class PostCampaignCheckoutViewModel: PostCampaignCheckoutViewModelType,
  PostCampaignCheckoutViewModelInputs,
  PostCampaignCheckoutViewModelOutputs {
  public init() {
    let initialData = Signal.combineLatest(
      self.configureWithDataProperty.signal,
      self.viewDidLoadProperty.signal
    )
    .map(first)
    .skipNil()

    let context = initialData.map(\.context)

    // MARK: Create checkout

    let createCheckoutEvents = self.configureWithDataProperty.signal
      .takeWhen(Signal.merge(self.viewDidLoadProperty.signal, self.userSessionStartedSignal))
      .skipNil()
      .map { data in
        let rewards = data.rewards
        let project = data.project
        let pledgeTotal = data.total
        let refTag = data.refTag

        let rewardsIDs = rewards.first?.isNoReward == true ? [] : rewards.map { $0.graphID }

        return CreateCheckoutInput(
          projectId: project.graphID,
          amount: String(format: "%.2f", pledgeTotal),
          locationId: "\(project.location.id)",
          rewardIds: rewardsIDs,
          refParam: refTag?.stringTag
        )
      }
      .switchMap { input in
        AppEnvironment.current.apiService
          .createCheckout(input: input)
          .ksr_delay(AppEnvironment.current.apiDelayInterval, on: AppEnvironment.current.scheduler)
          .materialize()
      }

    let checkoutId = createCheckoutEvents.values()
      .map { values in
        var checkoutId = values.checkout.id

        if let decoded = decodeBase64(checkoutId), let range = decoded.range(of: "Checkout-") {
          let id = decoded[range.upperBound...]
          checkoutId = String(id)
        }

        return checkoutId
      }

    let baseReward = initialData.map(\.rewards).map(\.first)

    // MARK: Configure Payment Methods

    let configurePaymentMethodsData = Signal.merge(
      initialData,
      initialData.takeWhen(self.userSessionStartedSignal)
    )

    self.configurePaymentMethodsViewControllerWithValue = configurePaymentMethodsData
      .compactMap { data -> PledgePaymentMethodsValue? in
        guard let user = AppEnvironment.current.currentUser else { return nil }
        let reward = data.baseReward

        return (user, data.project, reward, data.context, data.refTag, data.total, .paymentIntent)
      }

    // MARK: Configure CTA

    self.goToLoginSignup = initialData.takeWhen(self.goToLoginSignupSignal)
      .map { (LoginIntent.backProject, $0.project, $0.baseReward) }

    let isLoggedIn = Signal.merge(initialData.ignoreValues(), self.userSessionStartedSignal)
      .map { _ in AppEnvironment.current.currentUser }
      .map(isNotNil)

    self.paymentMethodsViewHidden = Signal.combineLatest(isLoggedIn, context)
      .map { isLoggedIn, context in
        !isLoggedIn || context.paymentMethodsViewHidden
      }

    self.showWebHelp = Signal.merge(
      self.termsOfUseTappedSignal,
      self.pledgeDisclaimerViewDidTapLearnMoreSignal.mapConst(.trust)
    )

    self.configurePledgeRewardsSummaryViewWithData = initialData
      .compactMap { data in
        let rewardsData = PostCampaignRewardsSummaryViewData(
          rewards: data.rewards,
          selectedQuantities: data.selectedQuantities,
          projectCountry: data.project.country,
          omitCurrencyCode: data.project.stats.omitUSCurrencyCode,
          shipping: data.shipping
        )
        let pledgeData = PledgeSummaryViewData(
          project: data.project,
          total: data.total,
          confirmationLabelHidden: true
        )
        return (rewardsData, data.bonusAmount, pledgeData)
      }

    // MARK: Validate Checkout Details On Submit

    let selectedCard = self.creditCardSelectedProperty.signal.skipNil()

    // MARK: - Validate Existing Cards

    /// Capture current users stored credit cards in the case that we need to validate an existing payment method
    let storedCardsEvent = Signal.merge(
      initialData.ignoreValues(),
      self.userSessionStartedSignal.ignoreValues()
    )
    .switchMap { _ in
      AppEnvironment.current.apiService
        .fetchGraphUser(withStoredCards: true)
        .ksr_debounce(.seconds(1), on: AppEnvironment.current.scheduler)
        .map { envelope in (envelope, false) }
        .prefix(value: (nil, true))
        .materialize()
    }

    let storedCardsValues = storedCardsEvent.values()
      .filter(second >>> isFalse)
      .map(first)
      .skipNil()
      .map { $0.me.storedCards.storedCards }

    let selectedExistingCard = selectedCard.filter { (_, _, isNewPaymentMethod: Bool) in
      !isNewPaymentMethod
    }

    let newPaymentIntentForExistingCards = initialData
      .takeWhen(selectedExistingCard)
      .switchMap { initialData in
        let projectId = initialData.project.graphID
        let pledgeTotal = initialData.total

        return AppEnvironment.current.apiService
          .createPaymentIntentInput(input: CreatePaymentIntentInput(
            projectId: projectId,
            amountDollars: String(format: "%.2f", pledgeTotal),
            digitalMarketingAttributed: nil
          ))
          .materialize()
      }

    let paymentIntentClientSecretForExistingCards = newPaymentIntentForExistingCards.values()
      .map { $0.clientSecret }

    let validateCheckoutExistingCardInput = Signal
      .combineLatest(
        checkoutId,
        selectedCard,
        paymentIntentClientSecretForExistingCards,
        storedCardsValues
      )

    // Runs validation for pre-existing cards that were created with setup intents originally but require payment intents for late pledges.
    let validateCheckoutExistingCard = validateCheckoutExistingCardInput
      .takeWhen(self.submitButtonTappedProperty.signal)
      .filter { _, selectedCard, _, _ in
        selectedCard.isNewPaymentMethod == false
      }
      .switchMap { checkoutId, selectedExistingCreditCard, paymentIntentClientSecret, storedCards in
        let (_, paymentMethodId, _) = selectedExistingCreditCard
        let selectedStoredCard = storedCards.first { $0.id == paymentMethodId }
        let selectedCardStripeCardId = selectedStoredCard?.stripeCardId ?? ""

        return AppEnvironment.current.apiService
          .validateCheckout(
            checkoutId: checkoutId,
            paymentSourceId: selectedCardStripeCardId,
            paymentIntentClientSecret: paymentIntentClientSecret
          )
          .ksr_delay(AppEnvironment.current.apiDelayInterval, on: AppEnvironment.current.scheduler)
          .materialize()
      }

    let validateCheckoutExistingCardSuccess: Signal<PaymentSourceValidation, Never> = Signal
      .combineLatest(paymentIntentClientSecretForExistingCards, selectedCard, storedCardsValues)
      .takeWhen(validateCheckoutExistingCard.values())
      .map { paymentIntentClientSecret, selectedCard, storedCards in
        let (_, paymentMethodId, _) = selectedCard
        let selectedStoredCard = storedCards.first { $0.id == paymentMethodId }
        let selectedCardStripeCardId = selectedStoredCard?.stripeCardId ?? ""

        return PaymentSourceValidation(
          paymentIntentClientSecret: paymentIntentClientSecret,
          selectedCardStripeCardId: selectedCardStripeCardId,
          requiresConfirmation: true
        )
      }

    // MARK: - Validate New Cards

    let validateCheckoutNewCardInput = Signal.combineLatest(checkoutId, selectedCard)

    // Runs validation for new cards that were created with payment intents.
    let validateCheckoutNewCard = validateCheckoutNewCardInput
      .takeWhen(self.submitButtonTappedProperty.signal)
      .filter { _, selectedCard in
        selectedCard.isNewPaymentMethod == true
      }
      .switchMap { checkoutId, selectedNewCreditCard in
        let (paymentSource, paymentMethodId, _) = selectedNewCreditCard

        return AppEnvironment.current.apiService
          .validateCheckout(
            checkoutId: checkoutId,
            paymentSourceId: paymentMethodId,
            paymentIntentClientSecret: paymentSource.paymentIntentClientSecret!
          )
          .ksr_delay(AppEnvironment.current.apiDelayInterval, on: AppEnvironment.current.scheduler)
          .materialize()
      }

    let validateCheckoutNewCardSuccess: Signal<PaymentSourceValidation, Never> = selectedCard
      .takeWhen(validateCheckoutNewCard.values())
      .map { paymentSource, _, _ in PaymentSourceValidation(
        paymentIntentClientSecret: paymentSource.paymentIntentClientSecret!,
        selectedCardStripeCardId: nil,
        requiresConfirmation: false // Newly added cards are confirmed in PledgePaymentMethodsViewController
      ) }

    self.validateCheckoutSuccess = Signal
      .merge(validateCheckoutNewCardSuccess, validateCheckoutExistingCardSuccess)

    let validateCheckoutError = Signal
      .merge(
        createCheckoutEvents.errors(),
        validateCheckoutExistingCard.errors(),
        validateCheckoutNewCard.errors()
      )

    self.showErrorBannerWithMessage = validateCheckoutError
      .map { _ in Strings.Something_went_wrong_please_try_again() }

    // MARK: ApplePay

    /*

     Order of operations:
     1) Apple pay button tapped
     2) Generate a new payment intent
     3) Present the payment authorization form
     4) Payment authorization form calls applePayContextDidCreatePayment with ApplePay params
     5) Payment authorization form calls paymentAuthorizationDidFinish
     */

    self.configureStripeIntegration = Signal.combineLatest(
      initialData,
      context
    )
    .filter { !$1.paymentMethodsViewHidden }
    .ignoreValues()
    .map { _ in
      (
        Secrets.ApplePay.merchantIdentifier,
        AppEnvironment.current.environmentType.stripePublishableKey
      )
    }

    let createPaymentIntentForApplePay: Signal<Signal<PaymentIntentEnvelope, ErrorEnvelope>.Event, Never> =
      self.configureWithDataProperty.signal
        .skipNil()
        .takeWhen(self.applePayButtonTappedSignal)
        .switchMap { initialData in
          let projectId = initialData.project.graphID
          let pledgeTotal = initialData.total

          return AppEnvironment.current.apiService
            .createPaymentIntentInput(input: CreatePaymentIntentInput(
              projectId: projectId,
              amountDollars: String(format: "%.2f", pledgeTotal),
              digitalMarketingAttributed: nil
            ))
            .ksr_delay(AppEnvironment.current.apiDelayInterval, on: AppEnvironment.current.scheduler)
            .materialize()
        }

    let newPaymentIntentForApplePayError: Signal<ErrorEnvelope, Never> = createPaymentIntentForApplePay
      .errors()

    let newPaymentIntentForApplePay: Signal<String, Never> = createPaymentIntentForApplePay
      .values()
      .map { $0.clientSecret }

    self.goToApplePayPaymentAuthorization = self
      .configureWithDataProperty
      .signal
      .skipNil()
      .combineLatest(with: newPaymentIntentForApplePay)
      .map { (
        data: PostCampaignCheckoutData,
        paymentIntent: String
      ) -> PostCampaignPaymentAuthorizationData? in
        let baseReward = data.baseReward

        return PostCampaignPaymentAuthorizationData(
          project: data.project,
          hasNoReward: baseReward.isNoReward,
          subtotal: baseReward.isNoReward ? baseReward.minimum : calculateAllRewardsTotal(
            addOnRewards: data.rewards,
            selectedQuantities: data.selectedQuantities
          ),
          bonus: data.bonusAmount ?? 0,
          shipping: data.shipping?.total ?? 0,
          total: data.total,
          merchantIdentifier: Secrets.ApplePay.merchantIdentifier,
          paymentIntent: paymentIntent
        )
      }
      .skipNil()

    // MARK: CompleteOnSessionCheckout

    let completeCheckoutWithCreditCardInput: Signal<GraphAPI.CompleteOnSessionCheckoutInput, Never> = Signal
      .combineLatest(self.confirmPaymentSuccessfulProperty.signal.skipNil(), checkoutId, selectedCard)
      .map { (
        clientSecret: String,
        checkoutId: String,
        selectedCard: (source: PaymentSourceSelected, paymentMethodId: String, isNewPaymentMethod: Bool)
      ) -> GraphAPI.CompleteOnSessionCheckoutInput in

        GraphAPI
          .CompleteOnSessionCheckoutInput(
            checkoutId: encodeToBase64("Checkout-\(checkoutId)"),
            paymentIntentClientSecret: clientSecret,
            paymentSourceId: selectedCard.isNewPaymentMethod ? nil : selectedCard.paymentMethodId,
            paymentSourceReusable: true,
            applePay: nil
          )
      }

    let completeCheckoutWithApplePayInput: Signal<GraphAPI.CompleteOnSessionCheckoutInput, Never> = Signal
      .combineLatest(newPaymentIntentForApplePay, checkoutId, self.applePayParamsSignal)
      .takeWhen(self.applePayContextDidCompleteSignal)
      .map {
        (
          clientSecret: String,
          checkoutId: String,
          applePayParams: ApplePayParams
        ) -> GraphAPI.CompleteOnSessionCheckoutInput in
        GraphAPI
          .CompleteOnSessionCheckoutInput(
            checkoutId: encodeToBase64("Checkout-\(checkoutId)"),
            paymentIntentClientSecret: clientSecret,
            paymentSourceId: nil,
            paymentSourceReusable: false,
            applePay: GraphAPI.ApplePayInput.from(applePayParams)
          )
      }

    let checkoutCompleteSignal = Signal
      .merge(
        completeCheckoutWithCreditCardInput,
        completeCheckoutWithApplePayInput
      )
      .switchMap { input in
        AppEnvironment.current.apiService.completeOnSessionCheckout(input: input).materialize()
      }

    let thanksPageData = Signal.combineLatest(initialData, baseReward)
      .map { initialData, baseReward -> ThanksPageData? in
        guard let reward = baseReward else { return nil }

        return (initialData.project, reward, nil, initialData.total)
      }

    self.checkoutComplete = thanksPageData.skipNil()
      .takeWhen(checkoutCompleteSignal.signal.values())
      .map { $0 }

    self.checkoutError = checkoutCompleteSignal.signal.errors()

    // MARK: - UI related to checkout flow

    let newCardActivatesPledgeButton = validateCheckoutNewCardInput
      .filter { _, selectedCard in
        selectedCard.isNewPaymentMethod == true
      }
      .mapConst(true)

    let existingCardActivatesPledgeButton = validateCheckoutExistingCardInput
      .filter { _, selectedCard, _, _ in
        selectedCard.isNewPaymentMethod == false
      }
      .mapConst(true)

    let pledgeButtonEnabled = Signal.merge(
      self.viewDidLoadProperty.signal.mapConst(false),
      newCardActivatesPledgeButton,
      existingCardActivatesPledgeButton
    )
    .skipRepeats()

    self.configurePledgeViewCTAContainerView = Signal.combineLatest(
      isLoggedIn,
      pledgeButtonEnabled,
      context
    )
    .map { isLoggedIn, pledgeButtonEnabled, context in
      PledgeViewCTAContainerViewData(
        isLoggedIn: isLoggedIn,
        isEnabled: pledgeButtonEnabled,
        context: context,
        willRetryPaymentMethod: false // Only retry in the `fixPaymentMethod` context.
      )
    }

    self.processingViewIsHidden = Signal.merge(
      // Processing view starts hidden, so show at the start of a pledge flow.
      self.submitButtonTappedProperty.signal.mapConst(false),
      self.applePayButtonTappedSignal.mapConst(false),
      // Hide view again whenever pledge flow is completed/cancelled/errors.
      newPaymentIntentForApplePayError.mapConst(true),
      validateCheckoutError.mapConst(true),
      self.checkoutTerminatedProperty.signal.mapConst(true),
      checkoutCompleteSignal.signal.mapConst(true),
      createCheckoutEvents.errors().mapConst(true)
    )

    // MARK: - Tracking

    // Page viewed event
    initialData
      .observeValues { data in
        AppEnvironment.current.ksrAnalytics.trackCheckoutPaymentPageViewed(
          project: data.project,
          reward: data.baseReward,
          pledgeViewContext: data.context,
          checkoutData: self.trackingDataFromCheckoutParams(data),
          refTag: data.refTag
        )
      }

    // Pledge button tapped event
    initialData
      .takeWhen(self.submitButtonTappedProperty.signal)
      .observeValues { data in
        AppEnvironment.current.ksrAnalytics.trackPledgeSubmitButtonClicked(
          project: data.project,
          reward: data.baseReward,
          typeContext: .creditCard,
          checkoutData: self.trackingDataFromCheckoutParams(data),
          refTag: data.refTag
        )
      }

    // Apple pay button tapped event
    initialData
      .takeWhen(self.applePayButtonTappedSignal)
      .observeValues { data in
        AppEnvironment.current.ksrAnalytics.trackPledgeSubmitButtonClicked(
          project: data.project,
          reward: data.baseReward,
          typeContext: .applePay,
          checkoutData: self.trackingDataFromCheckoutParams(data, isApplePay: true),
          refTag: data.refTag
        )
      }
  }

  // MARK: - Helpers

  private func trackingDataFromCheckoutParams(
    _ data: PostCampaignCheckoutData,
    isApplePay: Bool = false
  )
    -> KSRAnalytics.CheckoutPropertiesData {
    return checkoutProperties(
      from: data.project,
      baseReward: data.baseReward,
      addOnRewards: data.rewards,
      selectedQuantities: data.selectedQuantities,
      additionalPledgeAmount: data.bonusAmount ?? 0,
      pledgeTotal: data.total,
      shippingTotal: data.shipping?.total ?? 0,
      isApplePay: isApplePay
    )
  }

  // MARK: - Inputs

  private let checkoutTerminatedProperty = MutableProperty(())
  public func checkoutTerminated() {
    self.checkoutTerminatedProperty.value = ()
  }

  private let configureWithDataProperty = MutableProperty<PostCampaignCheckoutData?>(nil)
  public func configure(with data: PostCampaignCheckoutData) {
    self.configureWithDataProperty.value = data
  }

  private let confirmPaymentSuccessfulProperty = MutableProperty<String?>(nil)
  public func confirmPaymentSuccessful(clientSecret: String) {
    self.confirmPaymentSuccessfulProperty.value = clientSecret
  }

  private let creditCardSelectedProperty =
    MutableProperty<(source: PaymentSourceSelected, paymentMethodId: String, isNewPaymentMethod: Bool)?>(nil)
  public func creditCardSelected(
    source: PaymentSourceSelected,
    paymentMethodId: String,
    isNewPaymentMethod: Bool
  ) {
    self.creditCardSelectedProperty.value = (source, paymentMethodId, isNewPaymentMethod)
  }

  private let (goToLoginSignupSignal, goToLoginSignupObserver) = Signal<Void, Never>.pipe()
  public func goToLoginSignupTapped() {
    self.goToLoginSignupObserver.send(value: ())
  }

  private let (pledgeDisclaimerViewDidTapLearnMoreSignal, pledgeDisclaimerViewDidTapLearnMoreObserver)
    = Signal<Void, Never>.pipe()
  public func pledgeDisclaimerViewDidTapLearnMore() {
    self.pledgeDisclaimerViewDidTapLearnMoreObserver.send(value: ())
  }

  private let submitButtonTappedProperty = MutableProperty(())
  public func submitButtonTapped() {
    self.submitButtonTappedProperty.value = ()
  }

  private let (termsOfUseTappedSignal, termsOfUseTappedObserver) = Signal<HelpType, Never>.pipe()
  public func termsOfUseTapped(with helpType: HelpType) {
    self.termsOfUseTappedObserver.send(value: helpType)
  }

  private let (userSessionStartedSignal, userSessionStartedObserver) = Signal<Void, Never>.pipe()
  public func userSessionStarted() {
    self.userSessionStartedObserver.send(value: ())
  }

  private let viewDidLoadProperty = MutableProperty(())
  public func viewDidLoad() {
    self.viewDidLoadProperty.value = ()
  }

  private let (applePayButtonTappedSignal, applePayButtonTappedObserver) = Signal<Void, Never>.pipe()
  public func applePayButtonTapped() {
    self.applePayButtonTappedObserver.send(value: ())
  }

  private let (applePayParamsSignal, applePayParamsObserver) = Signal<ApplePayParams, Never>.pipe()
  public func applePayContextDidCreatePayment(params: ApplePayParams) {
    self.applePayParamsObserver.send(value: params)
  }

  private let (applePayContextDidCompleteSignal, applePayContextDidCompleteObserver)
    = Signal<Void, Never>.pipe()
  public func applePayContextDidComplete() {
    self.applePayContextDidCompleteObserver.send(value: ())
  }

  // MARK: - Outputs

  public let configurePaymentMethodsViewControllerWithValue: Signal<PledgePaymentMethodsValue, Never>
  public let configurePledgeRewardsSummaryViewWithData: Signal<(
    PostCampaignRewardsSummaryViewData,
    Double?,
    PledgeSummaryViewData
  ), Never>
  public let configurePledgeViewCTAContainerView: Signal<PledgeViewCTAContainerViewData, Never>
  public let configureStripeIntegration: Signal<StripeConfigurationData, Never>
  public let goToLoginSignup: Signal<(LoginIntent, Project, Reward?), Never>
  public let paymentMethodsViewHidden: Signal<Bool, Never>
  public let processingViewIsHidden: Signal<Bool, Never>
  public let showErrorBannerWithMessage: Signal<String, Never>
  public let showWebHelp: Signal<HelpType, Never>
  public let validateCheckoutSuccess: Signal<PaymentSourceValidation, Never>
  public let goToApplePayPaymentAuthorization: Signal<PostCampaignPaymentAuthorizationData, Never>
  public let checkoutComplete: Signal<ThanksPageData, Never>
  public let checkoutError: Signal<ErrorEnvelope, Never>

  public var inputs: PostCampaignCheckoutViewModelInputs { return self }
  public var outputs: PostCampaignCheckoutViewModelOutputs { return self }
}
