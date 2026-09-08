import SwiftUI
import Photos

struct RootView: View {
    @State private var library = RawLibrary()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-preview-widgets") {
                WidgetPreviewScreen(snapshot: WidgetSnapshot.load() ?? .placeholder)
            } else {
                content
            }
            #else
            content
            #endif
        }
        .animation(Motion.fade, value: library.status)
        .task { library.start() }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch library.status {
            case .notDetermined:
                PermissionView {
                    await library.requestAccess()
                }
                .transition(.opacity)

            case .denied, .restricted:
                DeniedView()
                    .transition(.opacity)

            default:
                LibraryView(library: library)
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - Permission

struct PermissionView: View {
    let allow: () async -> Void

    @State private var stage = 0
    @State private var requesting = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            PairGlyph(stage: stage, reduceMotion: reduceMotion)
                .padding(.bottom, 36)

            Text("RawDrop")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .padding(.bottom, 10)
                .opacity(stage >= 4 ? 1 : 0)
                .offset(y: stage >= 4 || reduceMotion ? 0 : 8)

            Text("Pulls the RAW hiding behind each camera import and hands it to Lightroom. Nothing leaves your phone.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .opacity(stage >= 5 ? 1 : 0)
                .offset(y: stage >= 5 || reduceMotion ? 0 : 8)

            Spacer()

            Button {
                guard !requesting else { return }
                requesting = true
                Task { await allow(); requesting = false }
            } label: {
                Text("Allow access to Photos")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
            }
            .buttonStyle(.glassProminent)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .opacity(stage >= 6 ? 1 : 0)
            .offset(y: stage >= 6 || reduceMotion ? 0 : 24)
        }
        .animation(reduceMotion ? Intro.fade : Intro.rise, value: stage)
        .task {
            if reduceMotion {
                try? await Task.sleep(for: .milliseconds(80))
                stage = 6
                return
            }
            var last = 0.0
            for (index, t) in Intro.timing.enumerated() {
                try? await Task.sleep(for: .seconds(t - last))
                last = t
                stage = index + 1
            }
        }
    }
}

// MARK: - Denied

struct DeniedView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.secondary)
            Text("Photos access is off")
                .font(.title3.weight(.semibold))
            Text("RawDrop can only find RAW files it is allowed to see.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: url)
                    .buttonStyle(.glass)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 40)
    }
}
