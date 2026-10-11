import AVKit
import PhotosUI
import SwiftUI

// MARK: - Root

struct ContentView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case camera = "Camera", editor = "Editor"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .camera

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 10) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch mode {
                case .camera: CameraScreen()
                case .editor: EditorScreen()
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
        }
        .foregroundStyle(.white)
        .tint(.cyan)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Camera

struct CameraScreen: View {
    @StateObject private var cam = CameraRecorder()

    var body: some View {
        VStack(spacing: 10) {
            topBar

            MetalPreview(provider: cam.previewImage(fitting:))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxHeight: .infinity)
                .overlay(alignment: .topTrailing) { compareButton }
                .overlay(alignment: .top) { toast(cam.message) }

            AdjustPanel(settings: $cam.settings)
            bottomBar
        }
        .onAppear { cam.start() }
        .onDisappear { cam.stop() }
        .overlay { if cam.permissionDenied { DeniedView(text: "Allow camera access in Settings to record.") } }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(Resolution.allCases) { r in
                    Button(r.rawValue) { cam.setResolution(r) }
                }
            } label: { chip(cam.resolution.rawValue) }

            Menu {
                ForEach([24, 30, 60], id: \.self) { f in
                    Button("\(f) fps") { cam.setFPS(f) }
                }
            } label: { chip("\(cam.fps) fps") }

            Spacer()

            if cam.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 9, height: 9)
                    Text(timeText(cam.recordSeconds)).font(.subheadline.monospacedDigit().weight(.semibold))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.red.opacity(0.25), in: Capsule())
            } else {
                chip("HEVC")
            }
        }
        .disabled(cam.isRecording)
    }

    /// Press and hold to see the picture without any adjustments.
    private var compareButton: some View {
        Image(systemName: cam.showOriginal ? "eye.slash" : "eye")
            .font(.subheadline.weight(.semibold))
            .frame(width: 38, height: 38)
            .background(.black.opacity(0.5), in: Circle())
            .padding(10)
            .onLongPressGesture(minimumDuration: 0, pressing: { pressing in
                cam.showOriginal = pressing
            }, perform: {})
            .accessibilityLabel("Hold to compare with original")
    }

    private var bottomBar: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(cam.availableLenses) { l in
                    Button { cam.setLens(l) } label: {
                        Text(l.rawValue)
                            .font(.caption.weight(.bold))
                            .frame(minWidth: 40, minHeight: 34)
                            .padding(.horizontal, 4)
                            .background(cam.lens == l ? Color.cyan : Color.white.opacity(0.12), in: Capsule())
                            .foregroundStyle(cam.lens == l ? Color.black : Color.white)
                    }
                }
            }
            .disabled(cam.isRecording)
            .opacity(cam.isRecording ? 0.4 : 1)

            Spacer()

            Button { cam.toggleRecording() } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 70, height: 70)
                    RoundedRectangle(cornerRadius: cam.isRecording ? 6 : 28, style: .continuous)
                        .fill(.red)
                        .frame(width: cam.isRecording ? 28 : 56, height: cam.isRecording ? 28 : 56)
                        .animation(.easeOut(duration: 0.2), value: cam.isRecording)
                }
            }
            .accessibilityLabel(cam.isRecording ? "Stop recording" : "Start recording")
        }
        .padding(.bottom, 4)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.white.opacity(0.12), in: Capsule())
    }

    private func timeText(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Editor

struct EditorScreen: View {
    @StateObject private var editor = VideoEditor()
    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Color(white: 0.08)
                if let player = editor.player {
                    VideoPlayer(player: player)
                } else if !editor.isLoading {
                    PhotosPicker(selection: $pickerItem, matching: .videos) {
                        VStack(spacing: 10) {
                            Image(systemName: "film.stack").font(.system(size: 40))
                            Text("Choose a video").font(.headline)
                            Text("Adjust its colors and detail, then save a new copy.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if editor.isLoading { ProgressView().controlSize(.large) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(maxHeight: .infinity)
            .overlay(alignment: .top) { toast(editor.message) }

            HStack {
                PhotosPicker(selection: $pickerItem, matching: .videos) {
                    Label("Open", systemImage: "photo.on.rectangle")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                Spacer()
                Button { editor.export() } label: {
                    Group {
                        if editor.isExporting {
                            HStack(spacing: 8) {
                                ProgressView(value: editor.exportProgress).frame(width: 60)
                                Text("\(Int(editor.exportProgress * 100))%").monospacedDigit()
                            }
                        } else {
                            Label("Save", systemImage: "square.and.arrow.down")
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color.cyan, in: Capsule())
                    .foregroundStyle(.black)
                }
                .disabled(editor.player == nil || editor.isExporting)
                .opacity(editor.player == nil ? 0.4 : 1)
            }

            AdjustPanel(settings: $editor.settings)
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await editor.load(item) }
        }
    }
}

// MARK: - Shared bits

@ViewBuilder
func toast(_ message: String?) -> some View {
    if let message {
        Text(message)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 10)
            .transition(.opacity)
    }
}

struct DeniedView: View {
    let text: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "video.slash.fill").font(.largeTitle)
            Text(text).font(.subheadline).multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

@main
struct ColorCamApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .statusBarHidden()
        }
    }
}
