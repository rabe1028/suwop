import MapKit
import SuwopShell
import SwiftUI

/// Rust supplies every group and its physical members. This screen only presents them.
struct OrganizationBrowserView: View {
    @ObservedObject var model: LibraryModel
    let sceneID: String
    @State private var reviewing: OrganizationMember?

    var body: some View {
        List {
            if let organization = model.view?.organization {
                if let error = organization.error {
                    Section { Text(error).foregroundStyle(.secondary) }
                }
                if organization.truncated {
                    Section { Text("表示上限に達しました。一部のグループ・写真を表示しています。") }
                }
                peopleSection(organization.people)
                Section {
                    Text("位置情報を近い座標でまとめています。地名や施設の特定は行いません。")
                        .foregroundStyle(.secondary)
                    ForEach(organization.places, id: \.id) { place in
                        NavigationLink {
                            members(.place(place.id))
                        } label: {
                            groupLabel(coordinate(place.latitude, place.longitude), count: place.members.count)
                        }.accessibilityIdentifier("organizationPlace-\(place.id)")
                    }
                    if organization.places.isEmpty {
                        Text("位置情報のある写真はありません")
                    }
                } header: { Label("撮影場所", systemImage: "mappin.and.ellipse") }
                Section {
                    if let reference = organization.referenceDate {
                        Text("\(reference.month)月\(reference.day)日 · \(reference.timeZone)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(organization.recollections, id: \.year) { recollection in
                        NavigationLink {
                            members(.recollection(recollection.year))
                        } label: {
                            groupLabel("\(recollection.year)年", count: recollection.members.count)
                        }.accessibilityIdentifier("organizationRecollection-\(recollection.year)")
                    }
                    if organization.recollections.isEmpty {
                        Text("過去の同じ日に撮影した写真はありません")
                    }
                } header: { Label("この日の思い出", systemImage: "calendar") }
                Section {
                    Text("登録された原本情報が一致するコピーです。写真の編集・説明・アルバムなどは異なる場合があります。ここでは確認だけ行い、削除・統合は行いません。")
                        .foregroundStyle(.secondary)
                    ForEach(organization.duplicates, id: \.id) { duplicate in
                        NavigationLink {
                            members(.duplicate(duplicate.id))
                        } label: {
                            groupLabel(duplicate.members.first?.name ?? "一致する原本", count: duplicate.members.count)
                        }.accessibilityIdentifier("organizationDuplicate-\(duplicate.id)")
                    }
                    if organization.duplicates.isEmpty {
                        Text("登録された原本情報が一致するコピーはありません")
                    }
                } header: { Label("重複コピーの確認", systemImage: "doc.on.doc") }
            } else {
                Text("整理情報を読み込んでいます")
            }
            Section("検索について") {
                Text("写真の内容の検索は「検索」タブで、対応モデルを利用できる場合に使えます。人物の分類は Immich が提供する情報を読み込みます。端末上での顔認識は行いません。")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("見つける")
        .accessibilityIdentifier("organizationBrowser")
        .task {
            guard !Task.isCancelled else { return }
            model.refreshOrganization()
        }
        .toolbar {
            Button("更新", systemImage: "arrow.clockwise") { model.refreshOrganization() }
                .disabled(model.isBusy)
        }
        .sheet(isPresented: Binding(get: { reviewing != nil }, set: {
            if !$0 {
                reviewing = nil
            }
        })) {
            if let member = reviewing {
                OrganizationMemberReview(model: model, member: member, sceneID: sceneID)
            }
        }
    }

    private func peopleSection(_ people: OrganizationPeopleView) -> some View {
        Section {
            Text("Immich で分類された人物と、現在表示できる写真だけを読み込みます。")
                .foregroundStyle(.secondary)
            Button(people.loading ? "人物情報を読み込み中…" : "Immich の人物を読み込む", systemImage: "person.crop.rectangle.stack") {
                model.browseOrganizationPeople()
            }.disabled(model.isBusy || people.loading || model.view?.organization.referenceDate == nil)
                .accessibilityIdentifier("organizationLoadPeople")
            if let error = people.error {
                Text(error).foregroundStyle(.secondary).accessibilityIdentifier("organizationPeopleError")
            }
            if people.partialCoverage {
                Text("確認対象は最大2,000コピーです。一部の写真のみ確認しました。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if people.truncated {
                Text("表示上限に達したため、一部の人物・写真を表示しています。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(people.groups, id: \.id) { person in
                NavigationLink {
                    members(.person(person.id))
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(person.name.isEmpty ? "名前のない人物" : person.name).fixedSize(horizontal: false, vertical: true)
                        Text("表示できるコピー \(person.members.count) 件")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("organizationPerson-\(person.personID)")
            }
            if people.loaded, people.groups.isEmpty, people.error == nil {
                Text("確認した写真に、表示できる人物情報はありません")
            }
        } header: { Label("Immich の人物", systemImage: "person.2") }
    }

    private func coordinate(_ latitude: Double, _ longitude: Double) -> String {
        "緯度 \(latitude.formatted(.number.precision(.fractionLength(2))))、経度 \(longitude.formatted(.number.precision(.fractionLength(2))))"
    }

    private func groupLabel(_ title: String, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            Text("\(count) コピー").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func members(_ reference: OrganizationGroupReference) -> some View {
        OrganizationMembersView(model: model, reference: reference) { member in
            reviewing = member
        }
    }
}

private struct OrganizationMembersView: View {
    @ObservedObject var model: LibraryModel
    let reference: OrganizationGroupReference
    let review: (OrganizationMember) -> Void

    var body: some View {
        let group = reference.resolve(in: model.view?.organization)
        let members = group?.members.filter { model.organizationMemberIsCurrent($0) } ?? []
        List {
            if members.isEmpty {
                OrganizationUnavailableContent(title: "このグループを表示できません")
            } else {
                if let place = group?.place {
                    Section {
                        Map(initialPosition: .region(MKCoordinateRegion(
                            center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
                            span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
                        )), interactionModes: []) {
                            Marker("おおよその撮影エリア", coordinate: CLLocationCoordinate2D(
                                latitude: place.latitude, longitude: place.longitude
                            ))
                        }
                        .frame(height: 200)
                        .accessibilityLabel("おおよその撮影エリア。\(group?.title ?? "")")
                        .accessibilityIdentifier("organizationPlaceMap")
                        Text("マーカーは近い座標でまとめたエリアの代表位置です。個々の写真の正確な撮影地点を示しません。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(members.enumerated()), id: \.offset) { _, member in
                    memberButton(member)
                }
            }
        }.navigationTitle(members.isEmpty ? "写真" : group?.title ?? "写真")
    }

    private func memberButton(_ member: OrganizationMember) -> some View {
        Button {
            guard model.organizationMemberIsCurrent(member),
                  let photo = model.photos.first(where: { $0.assets.contains { $0.key == member.key } })
            else { return }
            model.choosePreview(photo, key: member.key) { _ in
                guard model.organizationMemberIsCurrent(member) else { return }
                review(member)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(member.name).fixedSize(horizontal: false, vertical: true)
                Text(member.key.provider.title).font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(model.isBusy)
            .accessibilityIdentifier("organizationMember-\(member.key.assetID)")
    }
}

private struct OrganizationUnavailableContent: View {
    let title: String
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
            Text("写真やアクセス権限が変わりました。戻って整理情報を更新してください。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding()
    }
}

private struct OrganizationMemberReview: View {
    @ObservedObject var model: LibraryModel
    let member: OrganizationMember
    let sceneID: String
    @Environment(\.dismiss) private var dismiss

    private var valid: Bool {
        model.organizationMemberIsCurrent(member)
            && model.photos.contains { photo in
                photo.assets.contains { $0.key == member.key }
                    && model.displayedSource(photo)?.key == member.key
            }
    }

    var body: some View {
        if valid {
            PhotoViewer(model: model, key: member.key, sceneID: sceneID, organizationReview: true)
        } else {
            ScrollView {
                VStack(spacing: 16) {
                    OrganizationUnavailableContent(title: "このコピーを表示できません")
                    Button("閉じる") { dismiss() }
                }.padding()
            }
        }
    }
}
