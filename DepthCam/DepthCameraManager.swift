import AVFoundation
import CoreImage
import Photos
import SwiftUI
import UIKit

// MARK: - Depth sources

enum DepthSource: String, CaseIterable, Identifiable {
    case lidar = "LiDAR"
    case trueDepth = "TrueDepth IR"
    case dual = "Dual Camera"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .lidar: return "Back · infrared laser time-of-flight"
        case .trueDepth: return "Front · infrared dot projector"
        case .dual: return "Back · stereo from two lenses"
        }
    }

    var icon: String {
        switch self {
        case .lidar: return "dot.radiowaves.forward"
        case .trueDepth: return "faceid"
        case .dual: return "camera.aperture"
        }
    }

    var deviceTypes: [AVCaptureDevice.DeviceType] {
        switch self {
        case .lidar: return [.builtInLiDARDepthCamera]
        case .trueDepth: return [.builtInTrueDepthCamera]
        case .dual: return [.builtInDualWideCamera, .builtInDualCamera]
        }
    }

    var position: AVCaptureDevice.Position { self == .trueDepth ? .front : .back }

    /// How the sensor's landscape buffers must be turned to show upright in portrait.
    var orientation: CGImagePropertyOrientation { self == .trueDepth ? .leftMirrored : .right }

    func findDevice() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes,
                                         mediaType: .video,
                                         position: position).devices.first
    }
}

enum ViewMode: String, CaseIterable, Identifiable {
    case camera = "Camera"
    case mix = "Mix"
    case depth = "Depth"
    var id: String { rawValue }
}

private struct RenderSettings {
    var colormap: Colormap = .turbo
    var invert = false
    var autoRange = true
    var near: Float = 0.2
    var far: Float = 3.0
    var measurePoint = CGPoint(x: 0.5, y: 0.5)
    var orientation: CGImagePropertyOrientation = .right
}

// MARK: - Manager

final class DepthCameraManager: NSObject, ObservableObject {

    // Frames shown on screen (already rotated to portrait)
    @Published private(set) var videoImage: CGImage?
    @Published private(set) var depthImage: CGImage?
    @Published private(set) var aspect: CGFloat = 3.0 / 4.0

    // Depth controls
    @Published private(set) var availableSources: [DepthSource] = []
    @Published private(set) var source: DepthSource?
    @Published var viewMode: ViewMode = .mix
    @Published var blend: Double = 0.65
    @Published var colormap: Colormap = .turbo { didSet { pushSettings() } }
    @Published var invert = false { didSet { pushSettings() } }
    @Published var autoRange = true { didSet { pushSettings() } }
    @Published var near: Float = 0.2 { didSet { pushSettings() } }
    @Published var far: Float = 3.0 { didSet { pushSettings() } }
    @Published var measurePoint = CGPoint(x: 0.5, y: 0.5) { didSet { pushSettings() } }
    @Published var smoothing = true { didSet { applySmoothing() } }

    // Depth readouts
    @Published private(set) var measuredDistance: Float?
    @Published private(set) var sceneRange: ClosedRange<Float>?
    @Published private(set) var accuracy = "—"
    @Published private(set) var depthSize = "—"

    // Manual camera controls
    @Published private(set) var exposureSupported = false
    @Published private(set) var focusSupported = false
    @Published private(set) var wbSupported = false
    @Published private(set) var isoRange: ClosedRange<Float> = 25...3200
    @Published private(set) var shutterRange: ClosedRange<Double> = (1.0 / 8000.0)...(1.0 / 3.0)
    @Published private(set) var autoExposure = true
    @Published private(set) var autoFocus = true
    @Published private(set) var autoWB = true
    @Published private(set) var iso: Float = 100
    @Published private(set) var shutter: Double = 1.0 / 60.0
    @Published private(set) var lensPosition: Float = 0.5
    @Published private(set) var temperature: Float = 5500
    @Published private(set) var tint: Float = 0

    // Misc UI state
    @Published private(set) var lastThumb: UIImage?
    @Published private(set) var message: String?
    @Published private(set) var permissionDenied = false

    // Capture pipeline
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "depthcam.session")
    private let dataQueue = DispatchQueue(label: "depthcam.data", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private var device: AVCaptureDevice?           // sessionQueue only
    private var isConfigured = false               // sessionQueue only
    private var filteringEnabled = true            // sessionQueue only
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    // Shared between queues (guarded by lock)
    private let lock = NSLock()
    private var settings = RenderSettings()
    private var liveDevice: AVCaptureDevice?
    private var lastDepthImage: CGImage?
    private var pendingHeatmap: CGImage?

    // dataQueue only
    private var smoothNear: Float = 0
    private var smoothFar: Float = 0

    // main thread only
    private var messageToken = 0

    // MARK: Lifecycle

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setUp()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.setUp() } else { self?.permissionDenied = true }
                }
            }
        default:
            permissionDenied = true
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func select(_ newSource: DepthSource) {
        sessionQueue.async { [weak self] in self?.configure(newSource) }
    }

    func cycleSource() {
        guard availableSources.count > 1 else { return }
        let index = source.flatMap { availableSources.firstIndex(of: $0) } ?? 0
        select(availableSources[(index + 1) % availableSources.count])
    }

    private func setUp() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                let found = DepthSource.allCases.filter { $0.findDevice() != nil }
                DispatchQueue.main.async { self.availableSources = found }
                guard let first = found.first else {
                    self.post("No depth camera found on this device")
                    return
                }
                self.configure(first)
                self.isConfigured = true
            }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    // MARK: Session configuration (sessionQueue)

    private func configure(_ src: DepthSource) {
        guard let dev = src.findDevice() else {
            post("\(src.rawValue) is not available")
            return
        }

        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        synchronizer = nil

        guard let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
            session.commitConfiguration()
            post("Could not open \(src.rawValue)")
            return
        }
        session.addInput(input)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        depthOutput.alwaysDiscardsLateDepthData = true
        depthOutput.isFilteringEnabled = filteringEnabled
        if session.canAddOutput(depthOutput) { session.addOutput(depthOutput) }
        depthOutput.connection(with: .depthData)?.isEnabled = true

        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }

        // Pick a 4:3 video format (≤1920 wide) that can also deliver depth.
        let depthCapable = dev.formats.filter { !$0.supportedDepthDataFormats.isEmpty }
        let fourByThree = depthCapable.filter {
            let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return d.width * 3 == d.height * 4
        }
        let pool = fourByThree.isEmpty ? depthCapable : fourByThree
        let format = pool
            .filter { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width <= 1920 }
            .max { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width <
                   CMVideoFormatDescriptionGetDimensions($1.formatDescription).width } ?? pool.first

        do {
            try dev.lockForConfiguration()
            if let format {
                dev.activeFormat = format
                let floatDepth = format.supportedDepthDataFormats.filter {
                    let t = CMFormatDescriptionGetMediaSubType($0.formatDescription)
                    return t == kCVPixelFormatType_DepthFloat32 || t == kCVPixelFormatType_DepthFloat16
                }
                if let best = floatDepth.max(by: {
                    CMVideoFormatDescriptionGetDimensions($0.formatDescription).width <
                    CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
                }) {
                    dev.activeDepthDataFormat = best
                }
            }
            dev.unlockForConfiguration()
        } catch {
            post("Camera format could not be set")
        }

        photoOutput.maxPhotoQualityPrioritization = .quality
        photoOutput.isDepthDataDeliveryEnabled = photoOutput.isDepthDataDeliverySupported
        session.commitConfiguration()

        let sync = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
        sync.setDelegate(self, queue: dataQueue)
        synchronizer = sync
        device = dev

        lock.lock()
        settings.orientation = src.orientation
        liveDevice = dev
        lock.unlock()
        dataQueue.async { [weak self] in self?.smoothNear = 0; self?.smoothFar = 0 }

        readDeviceState(dev, src)
    }

    private func readDeviceState(_ d: AVCaptureDevice, _ src: DepthSource) {
        // Return everything to automatic when switching cameras.
        do {
            try d.lockForConfiguration()
            if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
            if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
            d.unlockForConfiguration()
        } catch {}

        let f = d.activeFormat
        let isoR: ClosedRange<Float> = f.minISO < f.maxISO ? f.minISO...f.maxISO : 25...3200
        let minS = max(f.minExposureDuration.seconds, 1.0 / 100_000.0)
        let maxS = min(max(f.maxExposureDuration.seconds, minS * 2), 0.5)
        let wb = d.temperatureAndTintValues(for: d.deviceWhiteBalanceGains)
        let expOK = d.isExposureModeSupported(.custom)
        let focusOK = d.isLockingFocusWithCustomLensPositionSupported
        let wbOK = d.isWhiteBalanceModeSupported(.locked)
        let isoNow = d.iso, shutterNow = d.exposureDuration.seconds, lensNow = d.lensPosition

        DispatchQueue.main.async {
            self.source = src
            self.exposureSupported = expOK
            self.focusSupported = focusOK
            self.wbSupported = wbOK
            self.isoRange = isoR
            self.shutterRange = minS...maxS
            self.autoExposure = true
            self.autoFocus = true
            self.autoWB = true
            self.iso = min(max(isoNow, isoR.lowerBound), isoR.upperBound)
            self.shutter = min(max(shutterNow, minS), maxS)
            self.lensPosition = lensNow
            self.temperature = wb.temperature
            self.tint = wb.tint
        }
    }

    private func pushSettings() {
        lock.lock()
        settings.colormap = colormap
        settings.invert = invert
        settings.autoRange = autoRange
        settings.near = near
        settings.far = far
        settings.measurePoint = measurePoint
        lock.unlock()
    }

    private func applySmoothing() {
        let on = smoothing
        sessionQueue.async { [weak self] in
            self?.filteringEnabled = on
            self?.depthOutput.isFilteringEnabled = on
        }
    }

    // MARK: Manual camera controls

    private func configureDevice(_ body: @escaping (AVCaptureDevice) -> Void) {
        sessionQueue.async { [weak self] in
            guard let d = self?.device else { return }
            do {
                try d.lockForConfiguration()
                body(d)
                d.unlockForConfiguration()
            } catch {}
        }
    }

    func setISO(_ value: Float) {
        iso = value
        autoExposure = false
        applyExposure()
    }

    func setShutter(_ seconds: Double) {
        shutter = seconds
        autoExposure = false
        applyExposure()
    }

    func setAutoExposure(_ on: Bool) {
        autoExposure = on
        if on {
            configureDevice { d in
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            }
        } else {
            applyExposure()
        }
    }

    private func applyExposure() {
        let isoValue = iso, seconds = shutter
        configureDevice { d in
            guard d.isExposureModeSupported(.custom) else { return }
            let f = d.activeFormat
            let clampedISO = min(max(isoValue, f.minISO), f.maxISO)
            let duration = CMTimeClampToRange(CMTime(seconds: seconds, preferredTimescale: 1_000_000),
                                              range: CMTimeRange(start: f.minExposureDuration, end: f.maxExposureDuration))
            d.setExposureModeCustom(duration: duration, iso: clampedISO, completionHandler: nil)
        }
    }

    func setLensPosition(_ value: Float) {
        lensPosition = value
        autoFocus = false
        configureDevice { d in
            guard d.isLockingFocusWithCustomLensPositionSupported else { return }
            d.setFocusModeLocked(lensPosition: value, completionHandler: nil)
        }
    }

    func setAutoFocus(_ on: Bool) {
        if on {
            autoFocus = true
            configureDevice { d in
                if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
            }
        } else {
            setLensPosition(lensPosition)
        }
    }

    func setWhiteBalance(temperature t: Float, tint tn: Float) {
        temperature = t
        tint = tn
        autoWB = false
        configureDevice { d in
            guard d.isWhiteBalanceModeSupported(.locked) else { return }
            var gains = d.deviceWhiteBalanceGains(for: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: t, tint: tn))
            let maxGain = d.maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1), maxGain)
            gains.greenGain = min(max(gains.greenGain, 1), maxGain)
            gains.blueGain = min(max(gains.blueGain, 1), maxGain)
            d.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        }
    }

    func setAutoWB(_ on: Bool) {
        if on {
            autoWB = true
            configureDevice { d in
                if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
            }
        } else {
            setWhiteBalance(temperature: temperature, tint: tint)
        }
    }

    // MARK: Photo capture

    func capture() {
        lock.lock()
        pendingHeatmap = lastDepthImage
        lock.unlock()

        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            let photoSettings: AVCapturePhotoSettings
            if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                photoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                photoSettings = AVCapturePhotoSettings()
            }
            if self.photoOutput.isDepthDataDeliveryEnabled {
                photoSettings.isDepthDataDeliveryEnabled = true
                photoSettings.embedsDepthDataInPhoto = true
            }
            photoSettings.photoQualityPrioritization = .balanced
            if let connection = self.photoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            self.photoOutput.capturePhoto(with: photoSettings, delegate: self)
        }
    }

    private func save(photoData: Data, heatmap: CGImage?) {
        let heatData = heatmap.flatMap { UIImage(cgImage: $0).pngData() }
        let thumb = heatmap.map { UIImage(cgImage: $0) } ?? UIImage(data: photoData)
        DispatchQueue.main.async { self.lastThumb = thumb }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                self?.post("Allow Photos access in Settings to save")
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: photoData, options: nil)
                if let heatData {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: heatData, options: nil)
                }
            }) { ok, _ in
                self?.post(ok ? "Saved photo (with depth) + depth map" : "Could not save to Photos")
            }
        }
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

    // MARK: Frame processing (dataQueue)

    private func process(depth raw: AVDepthData, video: CVPixelBuffer) {
        lock.lock()
        let s = settings
        let dev = liveDevice
        lock.unlock()

        let depthData = raw.depthDataType == kCVPixelFormatType_DepthFloat32
            ? raw : raw.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let map = depthData.depthDataMap
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)

        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(map)

        func row(_ y: Int) -> UnsafePointer<Float32> {
            UnsafePointer(base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self))
        }

        // Scene range from a subsample (2nd–98th percentile, ignores outliers).
        var samples: [Float] = []
        samples.reserveCapacity((w / 4 + 1) * (h / 4 + 1))
        for y in stride(from: 0, to: h, by: 4) {
            let r = row(y)
            for x in stride(from: 0, to: w, by: 4) {
                let v = r[x]
                if v.isFinite && v > 0 { samples.append(v) }
            }
        }
        var lo: Float = 0, hi: Float = 0
        if samples.count > 10 {
            samples.sort()
            lo = samples[Int(Float(samples.count - 1) * 0.02)]
            hi = samples[Int(Float(samples.count - 1) * 0.98)]
        }

        var nearM = s.near, farM = s.far
        if s.autoRange && hi > lo {
            smoothNear = smoothNear == 0 ? lo : smoothNear * 0.85 + lo * 0.15
            smoothFar = smoothFar == 0 ? hi : smoothFar * 0.85 + hi * 0.15
            nearM = smoothNear
            farM = max(smoothFar, smoothNear + 0.05)
        }
        let span = max(farM - nearM, 0.01)

        // Paint the depth map.
        let lut = s.colormap.lut
        var pixels = [UInt32](repeating: 0, count: w * h)
        pixels.withUnsafeMutableBufferPointer { out in
            for y in 0..<h {
                let r = row(y)
                for x in 0..<w {
                    let v = r[x]
                    guard v.isFinite && v > 0 else { continue }
                    var t = (v - nearM) / span
                    t = min(max(t, 0), 1)
                    if !s.invert { t = 1 - t }       // near = hot colors
                    out[y * w + x] = lut[Int(t * 255)]
                }
            }
        }

        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let painted = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: w * 4, space: colorSpace,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                                                       CGBitmapInfo.byteOrder32Little.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: true,
                                    intent: .defaultIntent)
        else { return }

        let paintedCI = CIImage(cgImage: painted)
        let depthCI = paintedCI.oriented(s.orientation)
        let videoCI = CIImage(cvPixelBuffer: video).oriented(s.orientation)
        guard let depthOut = ciContext.createCGImage(depthCI, from: depthCI.extent),
              let videoOut = ciContext.createCGImage(videoCI, from: videoCI.extent)
        else { return }

        // Distance at the measuring point (map screen point back into the sensor buffer).
        let transform = paintedCI.orientationTransform(for: s.orientation)
        let extent = CGRect(x: 0, y: 0, width: w, height: h).applying(transform)
        let screenPoint = CGPoint(x: extent.minX + s.measurePoint.x * extent.width,
                                  y: extent.minY + (1 - s.measurePoint.y) * extent.height)
        let sensorPoint = screenPoint.applying(transform.inverted())
        let cx = min(max(Int(sensorPoint.x), 0), w - 1)
        let cy = min(max(h - 1 - Int(sensorPoint.y), 0), h - 1)
        var sum: Float = 0, count: Float = 0
        for y in max(cy - 2, 0)...min(cy + 2, h - 1) {
            let r = row(y)
            for x in max(cx - 2, 0)...min(cx + 2, w - 1) {
                let v = r[x]
                if v.isFinite && v > 0 { sum += v; count += 1 }
            }
        }
        let distance: Float? = count > 0 ? sum / count : nil

        lock.lock()
        lastDepthImage = depthOut
        lock.unlock()

        let accuracyText = depthData.depthDataAccuracy == .absolute ? "Absolute" : "Relative"
        let sizeText = "\(w)×\(h)"
        let newAspect = CGFloat(videoOut.width) / CGFloat(videoOut.height)
        let live = dev.map { ($0.iso, $0.exposureDuration.seconds, $0.lensPosition) }
        let autoRangeOn = s.autoRange
        let range: ClosedRange<Float>? = hi > lo ? lo...hi : nil

        DispatchQueue.main.async {
            self.videoImage = videoOut
            self.depthImage = depthOut
            self.measuredDistance = distance
            self.sceneRange = range
            if self.accuracy != accuracyText { self.accuracy = accuracyText }
            if self.depthSize != sizeText { self.depthSize = sizeText }
            if abs(self.aspect - newAspect) > 0.001 { self.aspect = newAspect }
            if autoRangeOn && self.autoRange {
                self.near = nearM
                self.far = farM
            }
            if let live {
                if self.autoExposure { self.iso = live.0; self.shutter = live.1 }
                if self.autoFocus { self.lensPosition = live.2 }
            }
        }
    }
}

// MARK: - Delegates

extension DepthCameraManager: AVCaptureDataOutputSynchronizerDelegate {
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput collection: AVCaptureSynchronizedDataCollection) {
        guard let syncedDepth = collection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData,
              !syncedDepth.depthDataWasDropped,
              let syncedVideo = collection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData,
              !syncedVideo.sampleBufferWasDropped,
              let pixels = CMSampleBufferGetImageBuffer(syncedVideo.sampleBuffer)
        else { return }
        process(depth: syncedDepth.depthData, video: pixels)
    }
}

extension DepthCameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        lock.lock()
        let heatmap = pendingHeatmap
        pendingHeatmap = nil
        lock.unlock()

        guard error == nil, let data = photo.fileDataRepresentation() else {
            post("Photo capture failed")
            return
        }
        save(photoData: data, heatmap: heatmap)
    }
}
