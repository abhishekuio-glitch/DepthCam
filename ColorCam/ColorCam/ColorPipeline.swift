import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import Photos

// MARK: - Shared rendering objects

enum Rendering {
    static let device: MTLDevice = MTLCreateSystemDefaultDevice()!
    static let context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
}

// MARK: - Settings

enum PopColor: String, CaseIterable, Identifiable {
    case red = "Red", orange = "Orange", yellow = "Yellow", green = "Green"
    case cyan = "Cyan", blue = "Blue", purple = "Purple", magenta = "Magenta"

    var id: String { rawValue }

    /// Centre hue in degrees.
    var hue: Double {
        switch self {
        case .red: return 0
        case .orange: return 30
        case .yellow: return 55
        case .green: return 120
        case .cyan: return 185
        case .blue: return 220
        case .purple: return 275
        case .magenta: return 320
        }
    }
}

struct ColorSettings: Equatable {
    // Light
    var exposure: Double = 0        // -2...2 EV
    var contrast: Double = 1        // 0.5...1.5
    var highlights: Double = 0      // 0...1 (recover bright areas)
    var shadows: Double = 0         // 0...1 (lift dark areas)
    // Color
    var warmth: Double = 0          // -1 (cool) ... 1 (warm)
    var tint: Double = 0            // -50...50
    var saturation: Double = 1      // 0...2
    var vibrance: Double = 0        // -1...1
    // Detail
    var sharpness: Double = 0       // 0...2
    var noiseReduction: Double = 0  // 0...1
    // Color pop
    var popEnabled = false
    var popColor: PopColor = .blue
    var popBoost: Double = 0.6      // 0...1
    var popRange: Double = 30       // 10...60 degrees
    var isolate = false             // everything else black & white

    var popKey: PopKey { PopKey(color: popColor, boost: popBoost, range: popRange, isolate: isolate) }
}

struct PopKey: Equatable {
    let color: PopColor
    let boost: Double
    let range: Double
    let isolate: Bool
}

struct Preset: Identifiable {
    let name: String
    let settings: ColorSettings
    var id: String { name }

    static let all: [Preset] = [
        Preset(name: "Natural", settings: ColorSettings()),
        Preset(name: "Vivid", settings: {
            var s = ColorSettings()
            s.contrast = 1.12; s.vibrance = 0.45; s.saturation = 1.08; s.sharpness = 0.5
            return s
        }()),
        Preset(name: "Blue Pop", settings: {
            var s = ColorSettings()
            s.vibrance = 0.15; s.sharpness = 0.4
            s.popEnabled = true; s.popColor = .blue; s.popBoost = 0.85; s.popRange = 35
            return s
        }()),
        Preset(name: "Color Splash", settings: {
            var s = ColorSettings()
            s.contrast = 1.1
            s.popEnabled = true; s.popColor = .red; s.popBoost = 0.7; s.popRange = 25; s.isolate = true
            return s
        }()),
        Preset(name: "Cinematic", settings: {
            var s = ColorSettings()
            s.contrast = 1.15; s.saturation = 0.85; s.warmth = -0.15; s.highlights = 0.35; s.shadows = 0.2
            return s
        }()),
        Preset(name: "Warm", settings: {
            var s = ColorSettings()
            s.warmth = 0.45; s.vibrance = 0.2; s.contrast = 1.05
            return s
        }()),
        Preset(name: "Crisp", settings: {
            var s = ColorSettings()
            s.sharpness = 1.2; s.noiseReduction = 0.3; s.contrast = 1.08; s.highlights = 0.2
            return s
        }()),
    ]
}

// MARK: - Filter pipeline

final class ColorPipeline {
    private let lock = NSLock()
    private var cachedKey: PopKey?
    private var cachedCube: Data?
    private static let cubeSize = 32

    /// Applies every adjustment to an image. Safe to call from any thread.
    func apply(_ input: CIImage, _ s: ColorSettings) -> CIImage {
        var img = input

        if s.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = img
            f.ev = Float(s.exposure)
            img = f.outputImage ?? img
        }
        if s.warmth != 0 || s.tint != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = img
            f.neutral = CIVector(x: CGFloat(6500 + s.warmth * 3500), y: CGFloat(s.tint))
            f.targetNeutral = CIVector(x: 6500, y: 0)
            img = f.outputImage ?? img
        }
        if s.highlights != 0 || s.shadows != 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = img
            f.highlightAmount = Float(1 - s.highlights)
            f.shadowAmount = Float(s.shadows)
            img = f.outputImage ?? img
        }
        if s.contrast != 1 || s.saturation != 1 {
            let f = CIFilter.colorControls()
            f.inputImage = img
            f.contrast = Float(s.contrast)
            f.saturation = Float(s.saturation)
            f.brightness = 0
            img = f.outputImage ?? img
        }
        if s.vibrance != 0 {
            let f = CIFilter.vibrance()
            f.inputImage = img
            f.amount = Float(s.vibrance)
            img = f.outputImage ?? img
        }
        if s.noiseReduction > 0 {
            let f = CIFilter.noiseReduction()
            f.inputImage = img
            f.noiseLevel = Float(0.01 + s.noiseReduction * 0.05)
            f.sharpness = 0.4
            img = f.outputImage ?? img
        }
        if s.sharpness > 0 {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = img
            f.sharpness = Float(s.sharpness)
            f.radius = 1.7
            img = f.outputImage ?? img
        }
        if s.popEnabled {
            let f = CIFilter.colorCubeWithColorSpace()
            f.inputImage = img
            f.cubeDimension = Float(Self.cubeSize)
            f.cubeData = cube(for: s.popKey)
            f.colorSpace = Rendering.sRGB
            img = f.outputImage ?? img
        }
        return img.cropped(to: input.extent)
    }

    private func cube(for key: PopKey) -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let cachedCube, cachedKey == key { return cachedCube }
        let data = Self.makeCube(key)
        cachedKey = key
        cachedCube = data
        return data
    }

    /// Builds a colour lookup table that boosts one hue (and optionally greys out the rest).
    private static func makeCube(_ key: PopKey) -> Data {
        let n = cubeSize
        let target = key.color.hue
        var values = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let rf = Double(r) / Double(n - 1)
                    let gf = Double(g) / Double(n - 1)
                    let bf = Double(b) / Double(n - 1)
                    let (h, sat, v) = rgbToHSV(rf, gf, bf)

                    var d = abs(h - target)
                    d = min(d, 360 - d)
                    var w = max(0, 1 - d / key.range)
                    w = w * w * (3 - 2 * w)              // smooth edge
                    w *= min(1, sat / 0.2)               // ignore near-grey pixels

                    let boosted = min(1, sat * (1 + key.boost * 1.5 * w))
                    var (nr, ng, nb) = hsvToRGB(h, boosted, v)

                    if key.isolate {
                        let gray = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf
                        nr = gray + (nr - gray) * w
                        ng = gray + (ng - gray) * w
                        nb = gray + (nb - gray) * w
                    }
                    values[i] = Float(nr)
                    values[i + 1] = Float(ng)
                    values[i + 2] = Float(nb)
                    values[i + 3] = 1
                    i += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func rgbToHSV(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let delta = mx - mn
        var h = 0.0
        if delta > 0 {
            if mx == r { h = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = 60 * ((b - r) / delta + 2) }
            else { h = 60 * ((r - g) / delta + 4) }
        }
        if h < 0 { h += 360 }
        let s = mx == 0 ? 0 : delta / mx
        return (h, s, mx)
    }

    private static func hsvToRGB(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        let c = v * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (r, g, b): (Double, Double, Double)
        switch h {
        case ..<60: (r, g, b) = (c, x, 0)
        case ..<120: (r, g, b) = (x, c, 0)
        case ..<180: (r, g, b) = (0, c, x)
        case ..<240: (r, g, b) = (0, x, c)
        case ..<300: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return (r + m, g + m, b + m)
    }
}

// MARK: - Saving

enum PhotoSaver {
    enum SaveError: LocalizedError {
        case denied
        var errorDescription: String? { "Allow Photos access in Settings to save videos." }
    }

    static func saveVideo(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
        }
    }
}
