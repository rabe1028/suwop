#if compiler(>=6.2)
    import MapKit
#else
    // SDK 18 does not annotate MKLocalSearch.Response for Swift concurrency.
    // This view consumes each native result only on MainActor after the exact
    // request/freshness check; no response is sent to another Swift actor.
    // Remove this bridge when SDK 18 support ends.
    @preconcurrency import MapKit
#endif
import SwiftUI

/// Apple map UI selects coordinates only; Rust validates and authorizes the edit.
struct MetadataLocationPicker: View {
    let selected: (Double, Double) -> Void
    var searchPlaces: (@MainActor (String) async throws -> [MKMapItem])?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var position: MapCameraPosition = .automatic
    @State private var point: CLLocationCoordinate2D?
    @State private var search: MKLocalSearch?
    @State private var searchGeneration = UUID()
    @State private var failure: String?

    private func coordinate(_ item: MKMapItem) -> CLLocationCoordinate2D {
        #if compiler(>=6.2)
            if #available(iOS 26.0, macOS 26.0, *) {
                return item.location.coordinate
            } else {
                return item.placemark.coordinate
            }
        #else
            return item.placemark.coordinate
        #endif
    }

    var body: some View {
        NavigationStack {
            VStack {
                HStack {
                    TextField("地名・住所", text: $query).accessibilityIdentifier("metadataPlaceQuery")
                    Button("検索") { findPlaces() }.disabled(query.isEmpty)
                        .accessibilityIdentifier("metadataPlaceSearch")
                }.padding()
                if let failure {
                    Text(failure).foregroundStyle(.secondary)
                }
                if !results.isEmpty {
                    List(results.indices, id: \.self) { index in
                        let item = results[index]
                        Button(item.name ?? "場所") {
                            point = coordinate(item)
                            position = .region(MKCoordinateRegion(
                                center: coordinate(item),
                                span: MKCoordinateSpan(
                                    latitudeDelta: 0.02,
                                    longitudeDelta: 0.02
                                )
                            ))
                        }
                    }.frame(maxHeight: 160)
                }
                MapReader { proxy in
                    Map(position: $position) {
                        if let point {
                            Marker("選択した位置", coordinate: point)
                        }
                    }.onTapGesture { screenPoint in
                        point = proxy.convert(screenPoint, from: .local)
                    }.accessibilityIdentifier("metadataMap")
                }
                if let point {
                    Text("\(point.latitude), \(point.longitude)").font(.caption)
                }
            }.navigationTitle("地図から位置を選択")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("この位置を使う") {
                            if let point {
                                selected(point.latitude, point.longitude)
                                dismiss()
                            }
                        }.disabled(point == nil).accessibilityIdentifier("metadataUsePlace")
                    }
                }
        }.onDisappear { searchGeneration = UUID()
            search?.cancel()
            search = nil
        }
    }

    private func findPlaces() {
        search?.cancel()
        let generation = UUID()
        searchGeneration = generation
        if let searchPlaces {
            Task { @MainActor in
                do {
                    let found = try await searchPlaces(query)
                    guard searchGeneration == generation else { return }
                    results = found
                    failure = results.isEmpty ? "場所が見つかりませんでした。" : nil
                } catch {
                    if searchGeneration == generation {
                        failure = "場所を検索できませんでした。座標入力を利用してください。"
                    }
                }
            }
            return
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        let current = MKLocalSearch(request: request)
        search = current
        Task { @MainActor in
            do {
                let response = try await current.start()
                guard search === current else { return }
                results = response.mapItems
                failure = results.isEmpty ? "場所が見つかりませんでした。地図上で選択するか座標を入力できます。" : nil
            } catch {
                guard search === current else { return }
                failure = "場所を検索できませんでした。地図か座標入力を利用してください。"
            }
        }
    }
}
