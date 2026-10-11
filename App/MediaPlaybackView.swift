import AVKit
import Photos
import PhotosUI
import SwiftUI

enum NativeMediaContent {
    case video(AVPlayer)
    case live(PHLivePhoto)
}

struct MediaPlaybackView: View {
    let content: NativeMediaContent
    let name: String
    let close: () -> Void
    @State private var playCount = 1

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button(action: close) { Label("閉じる", systemImage: "xmark") }
                    .accessibilityLabel("再生を閉じる")
                Spacer()
                Text(name).lineLimit(1)
                Spacer()
            }.padding()
            switch content {
            case let .video(player):
                VideoPlayer(player: player).accessibilityIdentifier("originalVideoPlayer")
            case let .live(photo):
                LivePhotoSurface(photo: photo, playCount: playCount).accessibilityLabel("Live Photo の原本")
                Button { playCount += 1 } label: { Label("Live Photo を再生", systemImage: "livephoto.play") }
                    .padding()
            }
            Text("原本の再生です。編集結果は含みません。").font(.caption).foregroundStyle(.secondary).padding(.bottom)
        }.background(.black).foregroundStyle(.white).preferredColorScheme(.dark)
    }
}

#if os(iOS)
    private struct LivePhotoSurface: UIViewRepresentable {
        let photo: PHLivePhoto
        let playCount: Int
        func makeUIView(context: Context) -> PHLivePhotoView {
            let view = PHLivePhotoView()
            view.contentMode = .scaleAspectFit
            return view
        }

        func updateUIView(_ view: PHLivePhotoView, context: Context) {
            if view.livePhoto !== photo {
                view.livePhoto = photo
            }
            if context.coordinator.playCount != playCount {
                context.coordinator.playCount = playCount
                view.startPlayback(with: .full)
            }
        }

        static func dismantleUIView(_ view: PHLivePhotoView, coordinator: Coordinator) {
            view.stopPlayback()
            view.livePhoto = nil
        }

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        final class Coordinator { var playCount = 0 }
    }
#else
    private struct LivePhotoSurface: NSViewRepresentable {
        let photo: PHLivePhoto
        let playCount: Int
        func makeNSView(context: Context) -> PHLivePhotoView {
            let view = PHLivePhotoView()
            view.contentMode = .aspectFit
            return view
        }

        func updateNSView(_ view: PHLivePhotoView, context: Context) {
            if view.livePhoto !== photo {
                view.livePhoto = photo
            }
            if context.coordinator.playCount != playCount {
                context.coordinator.playCount = playCount
                view.startPlayback(with: .full)
            }
        }

        static func dismantleNSView(_ view: PHLivePhotoView, coordinator: Coordinator) {
            view.stopPlayback()
            view.livePhoto = nil
        }

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        final class Coordinator { var playCount = 0 }
    }
#endif
