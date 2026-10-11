import SwiftUI

/// Color palettes used to paint the depth map.
enum Colormap: String, CaseIterable, Identifiable {
    case turbo = "Turbo"
    case inferno = "Inferno"
    case gray = "Gray"

    var id: String { rawValue }

    /// Returns an RGB color (0...1) for a value x in 0...1.
    func rgb(_ value: Double) -> (Double, Double, Double) {
        let x = min(max(value, 0), 1)
        let r: Double, g: Double, b: Double
        switch self {
        case .turbo:
            r = Colormap.poly(x, [0.13572138, 4.61539260, -42.66032258, 132.13108234, -152.94239396, 59.28637943])
            g = Colormap.poly(x, [0.09140261, 2.19418839, 4.84296658, -14.18503333, 4.27729857, 2.82956604])
            b = Colormap.poly(x, [0.10667330, 12.64194608, -60.58204836, 110.36276771, -89.90310912, 27.34824973])
        case .inferno:
            r = Colormap.poly(x, [0.0002189403691192265, 0.1065134194856116, 11.60249308247187, -41.70399613139459, 77.162935699427, -71.31942824499214, 25.13112622477341])
            g = Colormap.poly(x, [0.001651004631001012, 0.5639564367884091, -3.972853965665698, 17.43639888205313, -33.40235894210092, 32.62606426397723, -12.24266895238567])
            b = Colormap.poly(x, [-0.01948089843709184, 3.932712388889277, -15.9423941062914, 44.35414519872813, -81.80730925738993, 73.20951985803202, -23.07032500287172])
        case .gray:
            r = x; g = x; b = x
        }
        return (min(max(r, 0), 1), min(max(g, 0), 1), min(max(b, 0), 1))
    }

    /// Horner evaluation, coefficients from lowest to highest power.
    private static func poly(_ x: Double, _ c: [Double]) -> Double {
        var result = 0.0
        for coefficient in c.reversed() {
            result = result * x + coefficient
        }
        return result
    }

    /// 256-entry lookup table packed as BGRA (little-endian ARGB) pixels.
    func makeLUT() -> [UInt32] {
        (0..<256).map { i in
            let (r, g, b) = rgb(Double(i) / 255.0)
            let ri = UInt32(r * 255.0), gi = UInt32(g * 255.0), bi = UInt32(b * 255.0)
            return 0xFF00_0000 | (ri << 16) | (gi << 8) | bi
        }
    }

    private static let turboLUT = Colormap.turbo.makeLUT()
    private static let infernoLUT = Colormap.inferno.makeLUT()
    private static let grayLUT = Colormap.gray.makeLUT()

    var lut: [UInt32] {
        switch self {
        case .turbo: return Colormap.turboLUT
        case .inferno: return Colormap.infernoLUT
        case .gray: return Colormap.grayLUT
        }
    }

    /// Gradient for the legend, running from near (leading) to far (trailing).
    func gradient(invert: Bool) -> Gradient {
        let stops = stride(from: 0.0, through: 1.0, by: 0.1).map { p -> Color in
            let (r, g, b) = rgb(invert ? p : 1 - p)
            return Color(red: r, green: g, blue: b)
        }
        return Gradient(colors: stops)
    }
}
