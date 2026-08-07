import AVFoundation
import SwiftUI
import ClockItCore

struct TuningView: View {
    @StateObject private var tracker = HandTracker()
    @State private var config = PoseConfig()
    @State private var flash = false

    var body: some View {
        HStack(spacing: 0) {
            CameraPreview(session: tracker.session)
                .frame(width: 360)
                .overlay(alignment: .topLeading) { presenceBadge.padding(10) }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    gauges
                    stateRow
                    Divider()
                    landmarks
                    Divider()
                    occlusion
                    Divider()
                    sliders
                    if let error = tracker.errorMessage {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
            .frame(width: 420)
        }
        .frame(minWidth: 780, minHeight: 620)
        .onAppear {
            tracker.onEvent = { _ in
                flash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { flash = false }
            }
            tracker.start()
        }
        .onDisappear { tracker.stop() }
        .onChange(of: config) { _, new in tracker.applyConfig(new) }
    }

    private var header: some View {
        HStack {
            Text(tracker.isLatched ? "Latched" : tracker.isRecording ? "Recording" : "Idle")
                .font(.headline)
            Spacer()
            Text(tracker.isRecording ? "●" : "○")
                .font(.system(size: 28, weight: .medium, design: .rounded))
                .foregroundStyle(flash ? Color.accentColor : .primary)
                .scaleEffect(flash ? 1.25 : 1)
                .animation(.spring(duration: 0.3), value: flash)
        }
    }

    // MARK: - Distance

    /// Two needles on the same axis. The top one is what the detector actually
    /// consumes; the bottom one is the candidate replacement, measured one joint
    /// further down each finger and normalized identically so the numbers are
    /// directly comparable. If you switch pairs, the thresholds move with them —
    /// read the IP/PIP row's contact and open values off this before deciding.
    private var gauges: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                distanceBar(tracker.distance, tinted: true, showThresholds: true)
                HStack {
                    Text(tracker.distance.map { String(format: "thumbTip↔middleTip   d = %.3f", $0) }
                         ?? "thumbTip↔middleTip   d = —  (landmarks not confident)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(tracker.distance == nil ? Color.red : Color.primary)
                    Spacer()
                    Text(String(format: "%.0f fps", tracker.effectiveFPS))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                distanceBar(tracker.altDistance, tinted: false, showThresholds: false)
                Text(tracker.altDistance.map { String(format: "thumbIP↔middlePIP    d = %.3f", $0) }
                     ?? "thumbIP↔middlePIP    d = —  (landmarks not confident)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(tracker.altDistance == nil ? Color.red : Color.secondary)
            }
        }
    }

    private func distanceBar(_ value: Double?, tinted: Bool, showThresholds: Bool) -> some View {
        GeometryReader { geo in
            let maxD = 1.2
            let x = { (v: Double) in geo.size.width * min(v / maxD, 1) }

            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)

                if let value {
                    Capsule()
                        .fill(tinted && value < config.contactEnter ? Color.accentColor : Color.secondary)
                        .frame(width: max(x(value), 3))
                }

                if showThresholds {
                    Rectangle().fill(.green).frame(width: 2)
                        .offset(x: x(config.contactEnter))
                    Rectangle().fill(.orange).frame(width: 2)
                        .offset(x: x(config.contactExit))
                }
            }
        }
        .frame(height: 16)
    }

    private var stateRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(stateColor)
                .frame(width: 9, height: 9)
            Text(stateLabel)
                .font(.system(.callout, design: .monospaced))
            Spacer()
        }
    }

    private var presenceBadge: some View {
        Text(tracker.handPresent ? "hand detected" : "no hand")
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: - Landmark confidence

    /// The detector only ever sees one `Double?`. This is why it went nil.
    ///
    /// The tick on each bar is the floor that landmark has to clear. Watch the
    /// first four while you hold contact: if middleTip drops under its floor
    /// every time your thumb comes across it, no threshold on the gauge above
    /// will fix that, and the IP/PIP pair is the answer.
    private var landmarks: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("landmark confidence")
                .font(.caption.weight(.semibold))

            confidenceRow("thumbTip", tracker.confidence.thumbTip, floor: HandTracker.tipConfidence)
            confidenceRow("middleTip", tracker.confidence.middleTip, floor: HandTracker.tipConfidence)
            confidenceRow("thumbIP", tracker.confidence.thumbIP, floor: HandTracker.tipConfidence)
            confidenceRow("middlePIP", tracker.confidence.middlePIP, floor: HandTracker.tipConfidence)
            confidenceRow("middleDIP", tracker.confidence.middleDIP, floor: HandTracker.tipConfidence)

            Text("scale pair")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            confidenceRow("wrist", tracker.confidence.wrist, floor: HandTracker.scaleConfidence)
            confidenceRow("middleMCP", tracker.confidence.middleMCP, floor: HandTracker.scaleConfidence)
        }
    }

    private func confidenceRow(_ label: String, _ value: Float?, floor: Float) -> some View {
        let level = Double(value ?? 0)
        let passes = (value ?? 0) > floor
        let barWidth: Double = 150

        return HStack(spacing: 8) {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 88, alignment: .leading)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: barWidth, height: 7)
                Capsule()
                    .fill(passes ? Color.green : Color.red)
                    .frame(width: max(barWidth * min(level, 1), 2), height: 7)
                Rectangle()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: 1, height: 12)
                    .offset(x: barWidth * Double(floor))
            }
            .frame(width: barWidth, height: 12)

            Text(value.map { String(format: "%.2f", $0) } ?? "—")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(passes ? Color.secondary : Color.red)
                .frame(width: 36, alignment: .trailing)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Occlusion

    /// The number that decides whether the tip pair survives.
    ///
    /// The denominator is frames where the detector believed the fingers were
    /// touching — loss while your hand is elsewhere is uninteresting. "worst"
    /// is the longest unbroken blackout, which is the figure `trackingGrace`
    /// has to absorb; anything longer than the grace would have cut a dictation
    /// off mid-sentence.
    private var occlusion: some View {
        let stats = tracker.stats
        let graceMs = config.trackingGrace * 1000
        let tipOver = stats.longestDropout > config.trackingGrace
        let altOver = stats.longestAltDropout > config.trackingGrace

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("dropouts while in contact")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Reset") { tracker.resetStats() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }

            Text(String(format: "%ld contact frames sampled", stats.contactFrames))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)

            // Expect 0. Anything else means frames were dropped from the
            // denominator, and the rates below are measuring a smaller sample
            // than you think.
            Text(String(format: "%ld Vision failures (excluded)", stats.visionFailures))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(stats.visionFailures > 0 ? Color.orange : Color.secondary)

            Text(String(format: "tip pair    nil %5.1f%%   worst %4.0f ms",
                        stats.nilRate * 100, stats.longestDropout * 1000))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(tipOver ? Color.red : Color.primary)

            Text(String(format: "IP/PIP      nil %5.1f%%   worst %4.0f ms",
                        stats.altNilRate * 100, stats.longestAltDropout * 1000))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(altOver ? Color.red : Color.primary)

            Text(String(format: "red above the %.0f ms grace — that dictation would have been cut", graceMs))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Hold the pose for 20–30 s the way you actually would — at your real desk height, turning your hand as you talk — then read both rows. Reset between trials.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Sliders

    private var sliders: some View {
        VStack(alignment: .leading, spacing: 12) {
            slider("contact enter", value: $config.contactEnter, range: 0.10...0.60, format: "%.2f")
            slider("contact exit", value: $config.contactExit, range: 0.20...0.90, format: "%.2f")
            slider("arming hold", value: $config.armingDuration, range: 0.200...1.500, format: "%.0f ms", scale: 1000)
            slider("latch after", value: $config.latchAfter, range: 3.0...20.0, format: "%.1f s")
            slider("tracking grace", value: $config.trackingGrace, range: 0.200...2.000, format: "%.0f ms", scale: 1000)
        }
    }

    private func slider(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String,
        scale: Double = 1
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: format, value.wrappedValue * scale))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private var stateLabel: String {
        switch tracker.state {
        case .open: "open"
        case .arming: "arming — hold it"
        case .active: "recording (hold)"
        case .latchedHolding: "latched — release your hand"
        case .latched: "latched — hand free"
        case .stopArming: "stopping — hold it"
        }
    }

    private var stateColor: Color {
        switch tracker.state {
        case .open: .secondary
        case .arming, .stopArming: .orange
        case .active: .accentColor
        case .latchedHolding, .latched: .green
        }
    }
}

/// Thin wrapper so you can see whether your hand is actually framed.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
