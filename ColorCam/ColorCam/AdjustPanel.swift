import SwiftUI

extension PopColor {
    var swatch: Color { Color(hue: hue / 360, saturation: 0.85, brightness: 0.95) }
}

/// The colour / light / detail controls, shared by the camera and the editor.
struct AdjustPanel: View {
    @Binding var settings: ColorSettings
    @State private var group: PanelTab = .presets

    enum PanelTab: String, CaseIterable, Identifiable {
        case presets = "Presets", light = "Light", color = "Color", detail = "Detail", pop = "Color Pop"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(PanelTab.allCases) { g in
                        Button { group = g } label: {
                            Text(g.rawValue)
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(group == g ? Color.cyan : Color.white.opacity(0.1), in: Capsule())
                                .foregroundStyle(group == g ? Color.black : Color.white)
                        }
                    }
                }
            }
            content
                .frame(height: 128, alignment: .top)
        }
    }

    @ViewBuilder private var content: some View {
        switch group {
        case .presets:
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Preset.all) { preset in
                            Button { settings = preset.settings } label: {
                                Text(preset.name)
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 10)
                                    .background(settings == preset.settings ? Color.cyan.opacity(0.9) : Color.white.opacity(0.1),
                                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .foregroundStyle(settings == preset.settings ? Color.black : Color.white)
                            }
                        }
                    }
                }
                Text("Pick a look, then fine-tune it in the other tabs.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

        case .light:
            VStack(spacing: 2) {
                row("Exposure", $settings.exposure, -2...2, 0) { String(format: "%+.1f", $0) }
                row("Contrast", $settings.contrast, 0.5...1.5, 1) { percent($0 - 1) }
                row("Highlights", $settings.highlights, 0...1, 0) { "-\(Int($0 * 100))" }
                row("Shadows", $settings.shadows, 0...1, 0) { "+\(Int($0 * 100))" }
            }

        case .color:
            VStack(spacing: 2) {
                row("Warmth", $settings.warmth, -1...1, 0) { String(format: "%+.0f", $0 * 100) }
                row("Tint", $settings.tint, -50...50, 0) { String(format: "%+.0f", $0) }
                row("Saturation", $settings.saturation, 0...2, 1) { percent($0 - 1) }
                row("Vibrance", $settings.vibrance, -1...1, 0) { percent($0) }
            }

        case .detail:
            VStack(spacing: 2) {
                row("Sharpness", $settings.sharpness, 0...2, 0) { "\(Int($0 * 50))" }
                row("Denoise", $settings.noiseReduction, 0...1, 0) { "\(Int($0 * 100))" }
                Text("Sharpness brings out fine detail. Denoise smooths grain in low light.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }

        case .pop:
            VStack(spacing: 6) {
                HStack {
                    Toggle("Pop", isOn: $settings.popEnabled).fixedSize()
                    Spacer()
                    Toggle("Rest B&W", isOn: $settings.isolate).fixedSize()
                        .disabled(!settings.popEnabled)
                }
                .font(.footnote.weight(.semibold))

                HStack(spacing: 0) {
                    ForEach(PopColor.allCases) { c in
                        Button {
                            settings.popColor = c
                            settings.popEnabled = true
                        } label: {
                            Circle()
                                .fill(c.swatch)
                                .frame(width: 28, height: 28)
                                .overlay(Circle().stroke(.white, lineWidth: settings.popColor == c ? 3 : 0))
                                .frame(maxWidth: .infinity)
                        }
                        .accessibilityLabel(c.rawValue)
                    }
                }

                row("Boost", $settings.popBoost, 0...1, 0.6) { "\(Int($0 * 100))" }
                row("Range", $settings.popRange, 10...60, 30) { "\(Int($0))°" }
            }
            .opacity(settings.popEnabled ? 1 : 0.6)
        }
    }

    private func row(_ label: String,
                     _ value: Binding<Double>,
                     _ range: ClosedRange<Double>,
                     _ neutral: Double,
                     format: @escaping (Double) -> String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.footnote.weight(.semibold))
                .frame(width: 76, alignment: .leading)
            Slider(value: value, in: range)
            Text(format(value.wrappedValue))
                .font(.footnote.monospacedDigit())
                .frame(width: 46, alignment: .trailing)
                .onTapGesture(count: 2) { value.wrappedValue = neutral }
        }
    }

    private func percent(_ v: Double) -> String {
        String(format: "%+.0f", v * 100)
    }
}
