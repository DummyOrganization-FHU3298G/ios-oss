import Foundation
import Library

enum ReportProjectInfoListItemType {
  case child
  case parent
}

struct ReportProjectInfoListItem: Identifiable {
  var type: ReportProjectInfoListItemType
  var id = UUID()
  var title: String
  var subtitle: String
  var subItems: [ReportProjectInfoListItem]?
  var exampleMenuItems: [ReportProjectInfoListItem]?
}

/// Hierarchical structure of the ReportProjectInfo List View
let listItems =
  [
    ReportProjectInfoListItem(
      type: .parent,
      title: Strings.This_project_breaks(),
      subtitle: Strings
        .Projects_may_not_offer(prohibited_items: "https://www.kickstarter.com/rules/prohibited?ref=project-page-report"),
      subItems: thisProjecBreaksSubListItems
    ),
    ReportProjectInfoListItem(
      type: .parent,
      title: Strings.Report_spam(),
      subtitle: Strings
        .Our(community_guidelines: "https://www.kickstarter.com/help/community?ref=project-page-report"),
      subItems: reportSpamSubListItems

    ),
    ReportProjectInfoListItem(
      type: .parent,
      title: Strings.Intellectual_property_violation(),
      subtitle: Strings.A_project_is_infringing(),
      subItems: intellectualProperySubListItems
    )
  ]

//// Sub items for This project breaks Our Rules
let thisProjecBreaksSubListItems =
  [
    ReportProjectInfoListItem(
      type: .child,
      title: Strings.Copying_reselling(),
      subtitle: Strings.Projects_cannot_plagiarize()
    ),
    ReportProjectInfoListItem(
      type: .child,
      title: Strings.Prototype_misrepresentation(),
      subtitle: Strings.Creators_must_be_transparent()
    ),
    ReportProjectInfoListItem(
      type: .child,
      title: Strings.Suspicious_creator_behavior(),
      subtitle: Strings.Project_creators_and_their()
    ),
    ReportProjectInfoListItem(
      type: .child,
      title: Strings.Not_raising_funds(),
      subtitle: Strings.Projects_on()
    )
  ]

//// Sub items for Report spam
let reportSpamSubListItems = [
  ReportProjectInfoListItem(
    type: .child,
    title: Strings.Spam(),
    subtitle: Strings.Ex_using()
  ),
  ReportProjectInfoListItem(
    type: .child,
    title: Strings.Abuse(),
    subtitle: Strings.Ex_posting()
  )
]

//// Sub items for intellectual property
let intellectualProperySubListItems = [
  ReportProjectInfoListItem(
    type: .child,
    title: Strings.Intellectual_property_violation(),
    subtitle: Strings.Kickstarter_takes_claims()
  )
]
