import Combine
import Foundation
import KsApi
import ReactiveSwift

public protocol ReportProjectFormViewModelInputs {
  func viewDidLoad()

  /// Submits a report using the createFlagging mutation
  func submitReport(
    contentId: String,
    kind: GraphAPI.FlaggingKind,
    details: String,
    clientMutationId: String?
  )
}

public protocol ReportProjectFormViewModelOutputs {}

public protocol ReportProjectFormViewModelType {
  var inputs: ReportProjectFormViewModelInputs { get }
  var outputs: ReportProjectFormViewModelOutputs { get }
}

public final class ReportProjectFormViewModel: ReportProjectFormViewModelType,
  ReportProjectFormViewModelInputs, ReportProjectFormViewModelOutputs, ObservableObject {
  /// Emits the currently logged in user's email
  @Published public var retrievedEmail: String? = nil
  @Published public var saveButtonEnabled: Bool = false

  public var bannerMessage: PassthroughSubject<MessageBannerViewViewModel, Never> = .init()
  public var detailsText: PassthroughSubject<String, Never> = .init()
  public var projectID: PassthroughSubject<String, Never> = .init()
  public var projectFlaggingKind: PassthroughSubject<GraphAPI.FlaggingKind, Never> = .init()
  public var saveTriggered: PassthroughSubject<Bool, Never> = .init()
  public var submitSuccess: PassthroughSubject<Void, Never> = .init()

  private var cancellables = Set<AnyCancellable>()

  public init() {
    Publishers
      .CombineLatest(self.projectFlaggingKind, self.detailsText)
      .map { !$0.1.isEmpty }
      .eraseToAnyPublisher()
      .assign(to: &$saveButtonEnabled)

    self.viewDidLoadProperty.signal
      .switchMap { _ in
        AppEnvironment.current
          .apiService
          .fetchGraphUser(withStoredCards: false)
          .ksr_delay(AppEnvironment.current.apiDelayInterval, on: AppEnvironment.current.scheduler)
          .materialize()
      }
      .map { event in
        event.value?.me.email
      }
      .skipNil()
      .assign(toCombine: &$retrievedEmail)

    let submitReportEvent = self.submitReportProperty.signal.skipNil()
      .map(CreateFlaggingInput.init(contentId:kind:details:clientMutationId:))
      .switchMap { input in
        AppEnvironment
          .current
          .apiService
          .createFlaggingInput(input: input)
          .ksr_delay(AppEnvironment.current.apiDelayInterval, on: AppEnvironment.current.scheduler)
          .materialize()
      }

    _ = submitReportEvent.errors()
      .observeForUI()
      .observeValues { [weak self] _ in
        let messageBannerViewViewModel = MessageBannerViewViewModel((
          type: .error,
          message: Strings.Something_went_wrong_please_try_again()
        ))

        self?.saveTriggered.send(false)
        self?.bannerMessage.send(messageBannerViewViewModel)
      }

    _ = submitReportEvent.values().ignoreValues()
      .observeForUI()
      .observeValues { [weak self] _ in
        let messageBannerViewViewModel = MessageBannerViewViewModel((
          type: .success,
          message: Strings.Your_message_has_been_sent()
        ))

        self?.saveTriggered.send(false)
        self?.bannerMessage.send(messageBannerViewViewModel)
        self?.submitSuccess.send()
      }

    /// Submits report on saveTriggered when saveButtonEnabled
    Publishers
      .CombineLatest4(self.saveTriggered, self.projectID, self.projectFlaggingKind, self.detailsText)
      .filter { triggeredValue, _, _, _ in
        triggeredValue
      }
      .sink(receiveValue: { [weak self] _, projectID, kind, details in
        self?.submitReport(contentId: projectID, kind: kind, details: details)
      })
      .store(in: &self.cancellables)
  }

  private let viewDidLoadProperty = MutableProperty(())
  public func viewDidLoad() {
    self.viewDidLoadProperty.value = ()
  }

  public var inputs: ReportProjectFormViewModelInputs {
    return self
  }

  public var outputs: ReportProjectFormViewModelOutputs {
    return self
  }

  private let submitReportProperty = MutableProperty<(String, GraphAPI.FlaggingKind, String, String?)?>(nil)
  public func submitReport(
    contentId: String,
    kind: GraphAPI.FlaggingKind,
    details: String,
    clientMutationId: String? = nil
  ) {
    self.submitReportProperty.value = (contentId, kind, details, clientMutationId)
  }
}
