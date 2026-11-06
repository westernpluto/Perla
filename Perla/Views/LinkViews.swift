import SwiftUI
import AVKit
import SafariServices

/// Opens a lesson, chapter, article or Bible chapter from another publication,
/// downloading the publication first when needed.
struct PubRefDestination: View {
    let ref: PubRef
    @State private var target: PubResolver.Target?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        Group {
            switch target {
            case .some(.reader(let route)):
                ReaderDestination(route: route)
            case .some(.contents(let route)):
                PubDestination(route: route)
            case .none:
                if let error {
                    ContentUnavailableView {
                        Label("Couldn't open \(ref.label.isEmpty ? "this" : ref.label)", systemImage: "book.closed")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try again") {
                            self.error = nil
                            attempt += 1
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text(ref.label.isEmpty ? "Opening…" : "Opening \(ref.label)…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: attempt) {
            guard target == nil else { return }
            do {
                target = try await PubResolver.resolve(ref)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Plays a jw.org video or song right here, instead of sending you to the website or another app.
struct MediaPlayerScreen: View {
    let item: MediaItem
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea(edges: .bottom)
                } else if let error {
                    ContentUnavailableView("Can't play this", systemImage: "play.slash", description: Text(error))
                        .foregroundStyle(.white)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        player?.pause()
                        dismiss()
                    }
                }
            }
        }
        .task {
            do {
                let url = try await MediaResolver.resolve(item)
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                let p = AVPlayer(url: url)
                player = p
                p.play()
            } catch {
                self.error = error.localizedDescription
            }
        }
        .onDisappear { player?.pause() }
    }
}

/// A web page inside the app.
struct InAppBrowser: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.dismissButtonStyle = .done
        return vc
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
