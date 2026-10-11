import AVFoundation
import CoreImage
import SwiftUI

enum Lens: String, CaseIterable, Identifiable {
    case ultraWide = "0.5x"
    case wide = "1x"
    case tele = "Tele"
    case front = "Front"

    var id: String { rawValue }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: return .builtInUltraWideCamera
        case .wide, .front: return .builtInWideAngleCamera
        case .tele: return .builtInTelephotoCamera
        }
    }

    var position: AVCaptureDevice.Position { self == .front ? .front : .back }

    var device: AVCaptureDevice? {
        AVCaptureDevice.default(deviceType, for: .video, position: position)
    }
}

enum Resolution: String, CaseIterable, Identifiable {
    case hd = "1080p"
    case uhd = "4K"
    var id: String { rawValue }
    var width: Int32 { self == .hd ? 1920 : 3840 }
    var preset: AVCaptureSession.Preset { self == .hd ? .hd1920x1080 : .hd4K3840x2160 }
}

final class CameraRecorder: NSObject, ObservableObject {

    // UI state
    @Published var settings = ColorSettings() { didSet { syncRenderState() } }
    @Published var showOriginal = false { didSet { syncRenderState() } }
    @Published private(set) var lens: Lens = .wide
    @Published private(set) var resolution: Resolution = .uhd
    @Published private(set) var fps: Int = 30
    @Published private(set) var availableLenses: [Lens] = []
    @Published private(set) var isRecording = false
    @Published private(set) var recordSeconds = 0
    @Published private(set) var message: String?
    @Published private(set) var permissionDenied = false

    // Capture
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "colorcam.session")
    private let dataQueue = DispatchQueue(label: "colorcam.data", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var outputsAdded = false          // sessionQueue only
    private var isSetUp = false               // sessionQueue only

    // Rendering
    private let pipeline = ColorPipeline()
    private let lock = NSLock()
    private var renderSettings = ColorSettings()   // guarded by lock
    private var renderOriginal = false             // guarded by lock
    private var latestFrame: CIImage?              // guarded by lock

    // Recording (dataQueue only)
    private enum RecState { case idle, recording }
    private var recState: RecState = .idle
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var currentFPS = 30
    private var hasAudio = false

    // main thread only
    private var timer: Timer?
    private var messageToken = 0

    // MARK: Lifecycle

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            requestMicThenSetUp()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.requestMicThenSetUp() } else { self?.permissionDenied = true }
                }
            }
        default:
            permissionDenied = true
        }
    }

    func stop() {
        if isRecording { stopRecording() }
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func requestMicThenSetUp() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in self?.setUp() }
        } else {
            setUp()
        }
    }

    private func setUp() {
        let lens = self.lens, res = self.resolution, fps = self.fps
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isSetUp {
                let found = Lens.allCases.filter { $0.device != nil }
                DispatchQueue.main.async { self.availableLenses = found }
                self.configure(lens: found.contains(lens) ? lens : (found.first ?? .wide), resolution: res, fps: fps)
                self.isSetUp = true
            }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func setLens(_ newLens: Lens) {
        guard !isRecording else { return }
        let res = resolution, f = fps
        sessionQueue.async { [weak self] in self?.configure(lens: newLens, resolution: res, fps: f) }
    }

    func setResolution(_ newRes: Resolution) {
        guard !isRecording else { return }
        let l = lens, f = fps
        sessionQueue.async { [weak self] in self?.configure(lens: l, resolution: newRes, fps: f) }
    }

    func setFPS(_ newFPS: Int) {
        guard !isRecording else { return }
        let l = lens, r = resolution
        sessionQueue.async { [weak self] in self?.configure(lens: l, resolution: r, fps: newFPS) }
    }

    // MARK: Configuration (sessionQueue)

    private func configure(lens: Lens, resolution: Resolution, fps: Int) {
        guard let dev = lens.device else {
            post("\(lens.rawValue) camera not available")
            return
        }

        session.beginConfiguration()

        for input in session.inputs {
            if let deviceInput = input as? AVCaptureDeviceInput, deviceInput.device.hasMediaType(.video) {
                session.removeInput(deviceInput)
            }
        }
        guard let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
            session.commitConfiguration()
            post("Could not open the camera")
            return
        }
        session.addInput(input)

        if !outputsAdded {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: dataQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
               let mic = AVCaptureDevice.default(for: .audio),
               let micInput = try? AVCaptureDeviceInput(device: mic),
               session.canAddInput(micInput),
               session.canAddOutput(audioOutput) {
                session.addInput(micInput)
                audioOutput.setSampleBufferDelegate(self, queue: dataQueue)
                session.addOutput(audioOutput)
                dataQueue.async { self.hasAudio = true }
            }
            outputsAdded = true
        }

        // Find a 16:9 format with the wanted width and frame rate.
        let candidates = dev.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            return d.width == resolution.width
                && d.width * 9 == d.height * 16
                && sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= Double(fps) }
        }
        var appliedFPS = fps
        var appliedRes = resolution
        if let format = candidates.first {
            do {
                try dev.lockForConfiguration()
                dev.activeFormat = format
                let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
                dev.activeVideoMinFrameDuration = duration
                dev.activeVideoMaxFrameDuration = duration
                dev.unlockForConfiguration()
            } catch {}
        } else {
            appliedFPS = 30
            if session.canSetSessionPreset(resolution.preset) {
                session.sessionPreset = resolution.preset
            } else {
                session.sessionPreset = .hd1920x1080
                appliedRes = .hd
            }
            post("\(resolution.rawValue) \(fps)fps not supported on this lens")
        }

        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = (lens == .front)
            }
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .auto
            }
        }

        session.commitConfiguration()

        dataQueue.async { self.currentFPS = appliedFPS }
        DispatchQueue.main.async {
            self.lens = lens
            self.resolution = appliedRes
            self.fps = appliedFPS
        }
    }

    private func syncRenderState() {
        lock.lock()
        renderSettings = settings
        renderOriginal = showOriginal
        lock.unlock()
    }

    // MARK: Preview

    /// Latest camera frame, scaled to fit size and filtered with the current settings.
    func previewImage(fitting size: CGSize) -> CIImage? {
        lock.lock()
        let frame = latestFrame
        let s = renderSettings
        let original = renderOriginal
        lock.unlock()

        guard let frame, frame.extent.width > 0 else { return nil }
        let scale = min(size.width / frame.extent.width, size.height / frame.extent.height)
        let scaled = frame.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return original ? scaled : pipeline.apply(scaled, s)
    }

    // MARK: Recording

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        recordSeconds = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.recordSeconds += 1
        }
        dataQueue.async {
            self.writer = nil
            self.recState = .recording
        }
    }

    private func stopRecording() {
        isRecording = false
        timer?.invalidate()
        timer = nil

        dataQueue.async { [weak self] in
            guard let self, self.recState == .recording else { return }
            self.recState = .idle
            guard let w = self.writer else { return }
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            let url = w.outputURL
            w.finishWriting { [weak self] in
                guard w.status == .completed else {
                    self?.post("Recording failed")
                    return
                }
                Task {
                    do {
                        try await PhotoSaver.saveVideo(url)
                        self?.post("Video saved to Photos")
                    } catch {
                        self?.post(error.localizedDescription)
                    }
                    try? FileManager.default.removeItem(at: url)
                }
            }
            self.writer = nil
            self.videoInput = nil
            self.audioInput = nil
            self.adaptor = nil
        }
    }

    /// Creates the file writer once the first frame tells us the exact size (dataQueue).
    private func makeWriter(width: Int, height: Int, start: CMTime) -> Bool {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ColorCam-\(UUID().uuidString).mov")
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }

        let bitrate = Int(Double(width * height) * Double(currentFPS) * 0.14)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: currentFPS,
            ],
        ]
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vIn.expectsMediaDataInRealTime = true
        let ad = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vIn,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ])
        guard w.canAdd(vIn) else { return false }
        w.add(vIn)

        var aIn: AVAssetWriterInput?
        if hasAudio,
           let audioSettings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any] {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if w.canAdd(input) {
                w.add(input)
                aIn = input
            }
        }

        guard w.startWriting() else { return false }
        w.startSession(atSourceTime: start)

        writer = w
        videoInput = vIn
        audioInput = aIn
        adaptor = ad
        return true
    }

    func post(_ text: String) {
        DispatchQueue.main.async {
            self.messageToken += 1
            let token = self.messageToken
            self.message = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if self.messageToken == token { self.message = nil }
            }
        }
    }
}

// MARK: - Frames

extension CameraRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === videoOutput {
            handleVideo(sampleBuffer)
        } else if output === audioOutput {
            handleAudio(sampleBuffer)
        }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixels)

        lock.lock()
        latestFrame = image
        let s = renderSettings
        lock.unlock()

        guard recState == .recording else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if writer == nil {
            let ok = makeWriter(width: CVPixelBufferGetWidth(pixels),
                                height: CVPixelBufferGetHeight(pixels),
                                start: time)
            if !ok {
                recState = .idle
                post("Could not start recording")
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.timer?.invalidate()
                }
                return
            }
        }

        guard let input = videoInput, input.isReadyForMoreMediaData,
              let ad = adaptor, let pool = ad.pixelBufferPool else { return }
        var outBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
        guard let outBuffer else { return }

        let filtered = pipeline.apply(image, s)
        Rendering.context.render(filtered, to: outBuffer, bounds: image.extent, colorSpace: Rendering.sRGB)
        ad.append(outBuffer, withPresentationTime: time)
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard recState == .recording, writer != nil,
              let input = audioInput, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }
}
