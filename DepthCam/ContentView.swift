import SwiftUI

struct ContentView: View {
    @StateObject private var cam = DepthCameraManager()
    @State private var panel: Panel = .range

    enum Panel: String, CaseIterable, Identifiable {
        case range = "Range", look = "Look", iso = "ISO", shutter = "Shutter", focus = "Focus", wb = "WB"
        var id: String { rawValue }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            VStack(spacing: 10) {
                topBar
                preview.frame(maxHeight: .infinity)
                Picker("View", selection: $cam.viewMode) {
                    ForEach(ViewMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                panelTabs
                panelBody.frame(height: 88, alignment: .top)
                bottomBar
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)

            if let msg = cam.message {
                Text(msg)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 52)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if cam.permissionDenied { deniedView }
        }
        .foregroundStyle(.white)
        .tint(.orange)
        .preferredColorScheme(.dark)
        .animation(.easeOut(duration: 0.2), value: cam.message)
        .onAppear { cam.start() }
        .onDisappear { cam.stop() }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(cam.availableSources) { s in
                    Button { cam.select(s) } label: {
                        Label("\(s.rawValue) — \(s.detail)", systemImage: s.icon)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: cam.source?.icon ?? "camera")
                    Text(cam.source?.rawValue ?? "Starting…").fontWeight(.semibold)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .font(.subheadline)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.white.opacity(0.12), in: Capsule())
            }

            Spacer()
            badge(cam.depthSize)
            badge(cam.accuracy)
            Button { cam.smoothing.toggle() } label: {
                Image(systemName: cam.smoothing ? "wand.and.stars" : "wand.and.stars.inverse")
                    .font(.subheadline)
                    .frame(width: 34, height: 34)
                    .background(cam.smoothing ? Color.orange.opacity(0.85) : Color.white.opacity(0.12), in: Circle())
            }
            .accessibilityLabel(cam.smoothing ? "Depth smoothing on" : "Depth smoothing off (raw)")
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit().weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.white.opacity(0.1), in: Capsule())
    }

    // MARK: Preview

    private var preview: some View {
        GeometryReader { geo in
            let size = geo.size
            let p = CGPoint(x: cam.measurePoint.x * size.width, y: cam.measurePoint.y * size.height)
            ZStack {
                Color(white: 0.08)

                if cam.viewMode != .depth, let v = cam.videoImage {
                    Image(decorative: v, scale: 1).resizable()
                }
                if cam.viewMode != .camera, let d = cam.depthImage {
                    Image(decorative: d, scale: 1)
                        .resizable()
                        .opacity(cam.viewMode == .mix ? cam.blend : 1)
                }

                Reticle()
                    .stroke(.white, lineWidth: 1.5)
                    .frame(width: 34, height: 34)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .position(p)

                Text(cam.measuredDistance.map(formatDistance) ?? "—")
                    .font(.system(.callout, design: .monospaced).weight(.bold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.black.opacity(0.65), in: Capsule())
                    .position(x: min(max(p.x, 54), size.width - 54),
                              y: p.y > 64 ? p.y - 36 : p.y + 36)

                VStack {
                    Spacer()
                    legend.padding(10)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                cam.measurePoint = CGPoint(x: min(max(g.location.x / size.width, 0), 1),
                                           y: min(max(g.location.y / size.height, 0), 1))
            })
        }
        .aspectRatio(cam.aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var legend: some View {
        HStack(spacing: 8) {
            Text(formatDistance(cam.near))
            Capsule()
                .fill(LinearGradient(gradient: cam.colormap.gradient(invert: cam.invert),
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 6)
            Text(formatDistance(cam.far))
        }
        .font(.caption2.monospacedDigit())
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.black.opacity(0.5), in: Capsule())
        .opacity(cam.viewMode == .camera ? 0 : 1)
    }

    // MARK: Control panels

    private var panelTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Panel.allCases) { p in
                    Button { panel = p } label: {
                        Text(p.rawValue)
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(panel == p ? Color.orange : Color.white.opacity(0.1), in: Capsule())
                            .foregroundStyle(panel == p ? Color.black : Color.white)
                    }
                }
            }
        }
    }

    @ViewBuilder private var panelBody: some View {
        switch panel {
        case .range:
            VStack(spacing: 6) {
                Toggle("Auto range", isOn: $cam.autoRange).font(.footnote.weight(.semibold))
                if cam.autoRange {
                    Text(sceneText)
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    row("Near", formatDistance(cam.near)) {
                        Slider(value: $cam.near, in: Float(0.05)...max(cam.far - 0.05, 0.1))
                    }
                    row("Far", formatDistance(cam.far)) {
                        Slider(value: $cam.far, in: min(cam.near + 0.05, 9.9)...Float(10))
                    }
                }
            }

        case .look:
            VStack(spacing: 6) {
                Picker("Colors", selection: $cam.colormap) {
                    ForEach(Colormap.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Invert colors", isOn: $cam.invert).font(.footnote.weight(.semibold))
                row("Blend", "\(Int(cam.blend * 100))%") {
                    Slider(value: $cam.blend, in: 0...1)
                }
                .opacity(cam.viewMode == .mix ? 1 : 0.35)
            }

        case .iso:
            if cam.exposureSupported {
                VStack(spacing: 6) {
                    Toggle("Auto exposure", isOn: Binding(get: { cam.autoExposure }, set: { cam.setAutoExposure($0) }))
                        .font(.footnote.weight(.semibold))
                    row("ISO", "\(Int(cam.iso))") {
                        Slider(value: Binding(get: { cam.iso }, set: { cam.setISO($0) }), in: cam.isoRange)
                    }
                }
            } else { unsupported }

        case .shutter:
            if cam.exposureSupported {
                VStack(spacing: 6) {
                    Toggle("Auto exposure", isOn: Binding(get: { cam.autoExposure }, set: { cam.setAutoExposure($0) }))
                        .font(.footnote.weight(.semibold))
                    row("Shutter", formatShutter(cam.shutter)) {
                        Slider(value: shutterBinding, in: 0...1)
                    }
                }
            } else { unsupported }

        case .focus:
            if cam.focusSupported {
                VStack(spacing: 6) {
                    Toggle("Auto focus", isOn: Binding(get: { cam.autoFocus }, set: { cam.setAutoFocus($0) }))
                        .font(.footnote.weight(.semibold))
                    row("Lens", String(format: "%.2f", cam.lensPosition)) {
                        Slider(value: Binding(get: { cam.lensPosition }, set: { cam.setLensPosition($0) }), in: 0...1)
                    }
                }
            } else { unsupported }

        case .wb:
            if cam.wbSupported {
                VStack(spacing: 4) {
                    Toggle("Auto white balance", isOn: Binding(get: { cam.autoWB }, set: { cam.setAutoWB($0) }))
                        .font(.footnote.weight(.semibold))
                    row("Temp", "\(Int(cam.temperature))K") {
                        Slider(value: Binding(get: { cam.temperature },
                                              set: { cam.setWhiteBalance(temperature: $0, tint: cam.tint) }),
                               in: 2500...9000)
                    }
                    row("Tint", "\(Int(cam.tint))") {
                        Slider(value: Binding(get: { cam.tint },
                                              set: { cam.setWhiteBalance(temperature: cam.temperature, tint: $0) }),
                               in: -50...50)
                    }
                }
            } else { unsupported }
        }
    }

    private var unsupported: some View {
        Text("This camera doesn't allow manual control of this setting.")
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row<S: View>(_ label: String, _ value: String, @ViewBuilder _ slider: () -> S) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.footnote.weight(.semibold)).frame(width: 54, alignment: .leading)
            slider()
            Text(value).font(.footnote.monospacedDigit()).frame(width: 64, alignment: .trailing)
        }
    }

    /// Log-scale slider so short and long shutter speeds are equally easy to pick.
    private var shutterBinding: Binding<Double> {
        let lo = cam.shutterRange.lowerBound, hi = cam.shutterRange.upperBound
        return Binding(
            get: { log(cam.shutter / lo) / log(hi / lo) },
            set: { cam.setShutter(lo * pow(hi / lo, $0)) }
        )
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack {
            Button {
                if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
            } label: {
                Group {
                    if let thumb = cam.lastThumb {
                        Image(uiImage: thumb).resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.1)
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Spacer()

            Button(action: cam.capture) {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                    Circle().fill(.white).frame(width: 60, height: 60)
                }
            }
            .accessibilityLabel("Take photo")

            Spacer()

            Button(action: cam.cycleSource) {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.title3)
                    .frame(width: 52, height: 52)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .disabled(cam.availableSources.count < 2)
            .accessibilityLabel("Switch depth camera")
        }
        .padding(.bottom, 4)
    }

    private var deniedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill").font(.largeTitle)
            Text("Camera access is off").font(.headline)
            Text("Allow camera access in Settings to see depth.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    // MARK: Formatting

    private var sceneText: String {
        guard let r = cam.sceneRange else { return "Point the camera at something…" }
        return "Scene: \(formatDistance(r.lowerBound)) – \(formatDistance(r.upperBound)). Drag on the image to measure."
    }
}

private func formatDistance(_ meters: Float) -> String {
    meters < 1 ? "\(Int((meters * 100).rounded())) cm" : String(format: "%.2f m", meters)
}

private func formatShutter(_ seconds: Double) -> String {
    seconds >= 0.5 ? String(format: "%.1fs", seconds) : "1/\(Int((1 / seconds).rounded()))"
}

/// Circle with a small crosshair, marks the measuring point.
struct Reticle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addEllipse(in: rect.insetBy(dx: 6, dy: 6))
        let c = CGPoint(x: rect.midX, y: rect.midY)
        p.move(to: CGPoint(x: c.x, y: rect.minY)); p.addLine(to: CGPoint(x: c.x, y: rect.minY + 10))
        p.move(to: CGPoint(x: c.x, y: rect.maxY - 10)); p.addLine(to: CGPoint(x: c.x, y: rect.maxY))
        p.move(to: CGPoint(x: rect.minX, y: c.y)); p.addLine(to: CGPoint(x: rect.minX + 10, y: c.y))
        p.move(to: CGPoint(x: rect.maxX - 10, y: c.y)); p.addLine(to: CGPoint(x: rect.maxX, y: c.y))
        return p
    }
}
