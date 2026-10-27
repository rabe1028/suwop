import Foundation
import SuwopShell

extension LibraryModel {
    func browseOrganizationPeople() {
        send(["type": .string("browseOrganizationPeople")])
    }

    func endOrganizationBrowse() {
        queueOrganizationNavigation(["type": .string("endOrganizationBrowse")])
    }

    func refreshOrganization(now: Date = Date()) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.dateComponents([.year, .month, .day], from: now)
        guard let year = date.year, let month = date.month, let day = date.day else { return }
        queueOrganizationNavigation([
            "type": .string("browseOrganization"),
            "reference": .object([
                "year": .number(Double(year)), "month": .number(Double(month)),
                "day": .number(Double(day)), "timeZone": .string(calendar.timeZone.identifier),
            ]),
        ])
    }

    func organizationMemberIsCurrent(_ member: OrganizationMember) -> Bool {
        presentationIndex?.organizationRevisions[member.key] == member.revision
    }

    /// Presentation validation only. Grouping and ordinary authorization are supplied by Rust.
    static func organizationMemberIsCurrent(
        key: AssetKey, revision: String, authorizedKeys: [AssetKey], snapshots: [LibrarySnapshot]
    ) -> Bool {
        LibraryPresentationIndex.organizationRevisions(
            authorizedKeys: Set(authorizedKeys), snapshots: snapshots
        )[key] == revision
    }
}

struct OrganizationGroupPresentation {
    let title: String
    let members: [OrganizationMember]
    let place: PlaceGroup?
}

/// Stable navigation stores only a group reference, never historical private labels.
enum OrganizationGroupReference {
    case place(String)
    case recollection(Int64)
    case duplicate(String)
    case person(String)

    func resolve(in organization: OrganizationView?) -> OrganizationGroupPresentation? {
        guard let organization else { return nil }
        switch self {
        case let .place(id):
            guard let group = organization.places.first(where: { $0.id == id }) else { return nil }
            let latitude = group.latitude.formatted(.number.precision(.fractionLength(2)))
            let longitude = group.longitude.formatted(.number.precision(.fractionLength(2)))
            return OrganizationGroupPresentation(
                title: "緯度 \(latitude)、経度 \(longitude)", members: group.members, place: group
            )
        case let .recollection(year):
            guard let group = organization.recollections.first(where: { $0.year == year }) else { return nil }
            return OrganizationGroupPresentation(title: "\(year)年の今日", members: group.members, place: nil)
        case let .person(id):
            guard let group = organization.people.groups.first(where: { $0.id == id }) else { return nil }
            return OrganizationGroupPresentation(
                title: group.name.isEmpty ? "名前のない人物" : group.name, members: group.members, place: nil
            )
        case let .duplicate(id):
            guard let group = organization.duplicates.first(where: { $0.id == id }) else { return nil }
            return OrganizationGroupPresentation(title: "原本情報が一致するコピー", members: group.members, place: nil)
        }
    }
}
