import AVFoundation
import CoreImage
import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A video picked from the library, copied into the app's temp folder.
struct VideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { file in
            SentTransferredFile(file.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("import-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return VideoFile(url: dest)
        }
    }
}

@MainActor
final class VideoEditor: ObservableObject {
    @Published var settings = ColorSettings() { didSet { scheduleUpdate() } }
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isLoading = false
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress: Double = 0
    @Published private(set) var message: String?

    private var asset: AVURLAsset?
    private let pipeline = ColorPipeline()
    private var updateTask: Task<Void, Never>?
    private var loopObserver: NSObjectProtocol?
    private var messageToken = 0

    func load(_ item: PhotosPickerItem) async {
        isLoading = true
        defer { isLoading = false }
        do {
            guard let file = try await item.loadTransferable(type: VideoFile.self) else {
                show("Could not open this video")
                return
            }
            await load(url: file.url)
        } catch {
            show("Could not open this video")
        }
    }

    private func load(url: URL) async {
        player?.pause()
        let newAsset = AVURLAsset(url: url)
        asset = newAsset
        let item = AVPlayerItem(asset: newAsset)
        item.videoComposition = try? await makeComposition(for: newAsset)

        let newPlayer = AVPlayer(playerItem: item)
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak newPlayer] _ in
            newPlayer?.seek(to: .zero)
            newPlayer?.play()
        }
        player = newPlayer
        newPlayer.play()
    }

    private func makeComposition(for asset: AVAsset) async throws -> AVVideoComposition {
        let s = settings
        let p = pipeline
        return try await AVVideoComposition.videoComposition(with: asset) { request in
            let source = request.sourceImage
            let output = p.apply(source.clampedToExtent(), s).cropped(to: source.extent)
            request.finish(with: output, context: nil)
        }
    }

    /// Re-applies the filters shortly after the sliders stop moving.
    private func scheduleUpdate() {
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, !Task.isCancelled,
                  let asset = self.asset,
                  let item = self.player?.currentItem,
                  let composition = try? await self.makeComposition(for: asset),
                  !Task.isCancelled
            else { return }
            item.videoComposition = composition
            if self.player?.rate == 0 {
                _ = await self.player?.seek(to: item.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    func export() {
        guard let asset, !isExporting else { return }
        isExporting = true
        exportProgress = 0
        Task {
            defer { isExporting = false }
            do {
                let composition = try await makeComposition(for: asset)
                guard let session = AVAssetExportSession(asset: asset,
                                                         presetName: AVAssetExportPresetHEVCHighestQuality) else {
                    show("Export not available for this video")
                    return
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ColorCam-\(UUID().uuidString).mov")
                session.outputURL = url
                session.outputFileType = .mov
                session.videoComposition = composition

                let progressTask = Task { [weak self] in
                    while !Task.isCancelled {
                        self?.exportProgress = Double(session.progress)
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                }
                await session.export()
                progressTask.cancel()

                guard session.status == .completed else {
                    show("Export failed: \(session.error?.localizedDescription ?? "unknown error")")
                    return
                }
                try await PhotoSaver.saveVideo(url)
                try? FileManager.default.removeItem(at: url)
                show("Saved to Photos")
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    private func show(_ text: String) {
        messageToken += 1
        let token = messageToken
        message = text
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if messageToken == token { message = nil }
        }
    }
}
