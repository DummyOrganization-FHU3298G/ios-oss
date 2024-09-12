import Combine
import Foundation
import Library
import SwiftUI

public class PPOContainerViewController: PagedContainerViewController<PPOContainerViewController.Page> {
  public override func viewDidLoad() {
    super.viewDidLoad()

    // TODO: Translate these strings (MBL-1558)
    self.title = "Activity"

    let ppoView = PPOView()
    let ppoViewController = UIHostingController(rootView: ppoView)
    ppoViewController.title = "Project Alerts"

    let activitiesViewController = ActivitiesViewController.instantiate()
    activitiesViewController.title = "Activity Feed"

    self.setPagedViewControllers([
      (.projectAlerts(.count(5)), ppoViewController),
      (.activityFeed(.dot), activitiesViewController)
    ])

    let tabBarController = self.tabBarController as? RootTabBarViewController

    ppoView.viewModel.navigationEvents.sink { nav in
      switch nav {
      case .backingPage:
        tabBarController?.switchToProfile()
      case .confirmAddress, .contactCreator, .fix3DSChallenge, .fixPaymentMethod, .survey:
        // TODO MBL-1451
        break
      }
    }.store(in: &self.subscriptions)
  }

  public enum Page: TabBarPage {
    case projectAlerts(TabBarBadge)
    case activityFeed(TabBarBadge)

    // TODO: Localize
    public var name: String {
      switch self {
      case .projectAlerts:
        "Project alerts"
      case .activityFeed:
        "Activity feed"
      }
    }

    public var badge: TabBarBadge {
      switch self {
      case let .projectAlerts(badge):
        badge
      case let .activityFeed(badge):
        badge
      }
    }

    public var id: String {
      self.name
    }
  }

  private var subscriptions = Set<AnyCancellable>()
}
