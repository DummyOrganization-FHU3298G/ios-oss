import Combine
@testable import Kickstarter_Framework
@testable import KsApi
import XCTest

class PPOViewModelTests: XCTestCase {
  var viewModel: PPOViewModel!
  var cancellables: Set<AnyCancellable>!

  override func setUp() {
    super.setUp()
    self.viewModel = PPOViewModel()
    self.cancellables = []
  }

  override func tearDown() {
    self.viewModel = nil
    self.cancellables = nil
    super.tearDown()
  }

  func testInitialLoading_Once() throws {
    let expectation = XCTestExpectation(description: "Initial loading")
    expectation.expectedFulfillmentCount = 3

    var values: [PPOViewModelPaginator.Results] = []
    self.viewModel.$results
      .sink { value in
        values.append(value)
        expectation.fulfill()
      }
      .store(in: &self.cancellables)

    withEnvironment(apiService: MockService(
      fetchPledgedProjectsResult: Result.success(try self.pledgedProjectsData())
    )) {
      self.viewModel.viewDidAppear()
    }

    wait(for: [expectation], timeout: 0.1)

    guard
      case .unloaded = values[0],
      case .loading = values[1],
      case let .allLoaded(data, _) = values[2]
    else {
      return XCTFail()
    }
    XCTAssertEqual(data.count, 3)
    XCTAssertEqual(data.count, 3)
  }

  func testInitialLoading_Twice() throws {
    let expectation = XCTestExpectation(description: "Initial loading twice")
    expectation.expectedFulfillmentCount = 3

    var values: [PPOViewModelPaginator.Results] = []
    self.viewModel.$results
      .sink { value in
        values.append(value)
        expectation.fulfill()
      }
      .store(in: &self.cancellables)

    withEnvironment(apiService: MockService(
      fetchPledgedProjectsResult: Result.success(try self.pledgedProjectsData())
    )) {
      self.viewModel.viewDidAppear()
      self.viewModel.viewDidAppear() // This should not trigger another load
    }

    wait(for: [expectation], timeout: 0.1)

    XCTAssertEqual(values.count, 3)

    guard
      case .unloaded = values[0],
      case .loading = values[1],
      case let .allLoaded(data, _) = values[2]
    else {
      return XCTFail()
    }
    XCTAssertEqual(data.count, 3)
  }

  func testPullToRefresh_Once() throws {
    let expectation = XCTestExpectation(description: "Pull to refresh")
    expectation.expectedFulfillmentCount = 5

    var values: [PPOViewModelPaginator.Results] = []

    self.viewModel.$results
      .sink { value in
        values.append(value)
        expectation.fulfill()
      }
      .store(in: &self.cancellables)

    withEnvironment(apiService: MockService(
      fetchPledgedProjectsResult: Result.success(try self.pledgedProjectsData(cursors: 1...3))
    )) {
      self.viewModel.viewDidAppear() // Initial load
    }

    withEnvironment(apiService: MockService(
      fetchPledgedProjectsResult: Result.success(try self.pledgedProjectsData(cursors: 1...2))
    )) {
      self.viewModel.pullToRefresh() // Refresh
    }

    wait(for: [expectation], timeout: 0.1)

    XCTAssertEqual(values.count, 5)

    guard
      case .unloaded = values[0],
      case .loading = values[1],
      case let .allLoaded(firstData, _) = values[2]
    else {
      return XCTFail()
    }
    XCTAssertEqual(firstData.count, 3)

    guard
      case .loading = values[3],
      case let .allLoaded(secondData, _) = values[4]
    else {
      return XCTFail()
    }
    XCTAssertEqual(secondData.count, 2)
  }

  func testPullToRefresh_Twice() throws {
    let expectation = XCTestExpectation(description: "Pull to refresh twice")
    expectation.expectedFulfillmentCount = 7

    var values: [PPOViewModelPaginator.Results] = []

    self.viewModel.$results
      .sink { value in
        values.append(value)
        expectation.fulfill()
      }
      .store(in: &self.cancellables)

    withEnvironment(apiService: MockService(
      fetchPledgedProjectsResult: Result.success(try self.pledgedProjectsData(cursors: 1...3))
    )) {
      self.viewModel.viewDidAppear() // Initial load
    }

    withEnvironment(apiService: MockService(
      fetchPledgedProjectsResult: Result.success(try self.pledgedProjectsData(cursors: 1...2))
    )) {
      self.viewModel.pullToRefresh() // Refresh
    }

    withEnvironment(apiService: MockService(
      fetchPledgedProjectsResult: Result.success(try self.pledgedProjectsData(cursors: 1...16))
    )) {
      self.viewModel.pullToRefresh() // Refresh a second time
    }

    wait(for: [expectation], timeout: 0.1)

    XCTAssertEqual(values.count, 7)

    guard
      case .unloaded = values[0],
      case .loading = values[1],
      case let .allLoaded(firstData, _) = values[2]
    else {
      return XCTFail()
    }
    XCTAssertEqual(firstData.count, 3)

    guard
      case .loading = values[3],
      case let .allLoaded(secondData, _) = values[4]
    else {
      return XCTFail()
    }
    XCTAssertEqual(secondData.count, 2)

    guard
      case .loading = values[5],
      case let .allLoaded(thirdData, _) = values[6]
    else {
      return XCTFail()
    }
    XCTAssertEqual(thirdData.count, 16)
  }

  func testLoadMore() throws {
    let expectation = XCTestExpectation(description: "Load more")
    expectation.expectedFulfillmentCount = 5

    var values: [PPOViewModelPaginator.Results] = []

    self.viewModel.$results
      .sink { value in
        values.append(value)
        expectation.fulfill()
      }
      .store(in: &self.cancellables)

    withEnvironment(apiService: MockService(
      fetchPledgedProjectsResult: Result.success(try self.pledgedProjectsData(
        cursors: 1...4,
        hasNextPage: true
      ))
    )) {
      self.viewModel.viewDidAppear() // Initial load
    }
    withEnvironment(apiService: MockService(
      fetchPledgedProjectsResult: Result.success(try self.pledgedProjectsData(cursors: 5...7))
    )) {
      self.viewModel.loadMore() // Load next page
    }

    wait(for: [expectation], timeout: 0.1)

    XCTAssertEqual(values.count, 5)

    guard
      case .unloaded = values[0],
      case .loading = values[1],
      case let .someLoaded(firstData, cursor, _, _) = values[2]
    else {
      return XCTFail()
    }
    XCTAssertEqual(firstData.count, 4)
    XCTAssertEqual(cursor, "4")

    guard
      case .loading = values[3],
      case let .allLoaded(secondData, _) = values[4]
    else {
      return XCTFail()
    }
    XCTAssertEqual(secondData.count, 7)
  }

  func testNavigationBackedProjects() {
    self.verifyNavigationEvent({ self.viewModel.openBackedProjects() }, event: .backedProjects)
  }

  func testNavigationConfirmAddress() {
    self.verifyNavigationEvent(
      { self.viewModel.confirmAddress(from: Project.template) },
      event: .confirmAddress
    )
  }

  func testNavigationContactCreator() {
    self.verifyNavigationEvent(
      { self.viewModel.contactCreator(from: Project.template) },
      event: .contactCreator
    )
  }

  func testNavigationFix3DSChallenge() {
    self.verifyNavigationEvent(
      { self.viewModel.fix3DSChallenge(from: Project.template) },
      event: .fix3DSChallenge
    )
  }

  func testNavigationFixPaymentMethod() {
    self.verifyNavigationEvent(
      { self.viewModel.fixPaymentMethod(from: Project.template) },
      event: .fixPaymentMethod
    )
  }

  func testNavigationOpenSurvey() {
    self.verifyNavigationEvent({ self.viewModel.openSurvey(from: Project.template) }, event: .survey)
  }

  // Setup the view model to monitor navigation events, then run the closure, then check to make sure only that one event fired
  private func verifyNavigationEvent(_ closure: () -> Void, event: PPONavigationEvent) {
    let beforeResults: PPOViewModelPaginator.Results = self.viewModel.results

    let expectation = self.expectation(description: "VerifyNavigationEvent \(event)")

    var values: [PPONavigationEvent] = []
    self.viewModel.navigationEvents
      .collect(.byTime(DispatchQueue.main, 0.1))
      .sink(receiveValue: { v in
        values = v
        expectation.fulfill()
      })
      .store(in: &self.cancellables)

    closure()

    self.wait(for: [expectation], timeout: 1)

    let afterResults: PPOViewModelPaginator.Results = self.viewModel.results

    XCTAssertEqual(values.count, 1)
    guard case event = values[0] else {
      return XCTFail()
    }

    XCTAssertEqual(beforeResults, afterResults)
  }

  private func pledgedProjectsData(
    cursors: ClosedRange<Int> = 1...3,
    hasNextPage: Bool = false
  ) throws -> PledgedProjectOverviewCardsEnvelope {
    PledgedProjectOverviewCardsEnvelope(
      cards: cursors.map { _ in self.projectCard() },
      totalCount: cursors.count,
      cursor: hasNextPage ? "\(cursors.upperBound)" : nil
    )
  }

  private func projectCard() -> PledgedProjectOverviewCard {
    PledgedProjectOverviewCard.previewTemplates[0]
  }
}
