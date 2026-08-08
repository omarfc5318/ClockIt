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
    /// consumes — the mean distance from the thumb tip to every fingertip that
    /// cleared the confidence floor. The bottom one is the largest of those same
    /// per-finger distances: the finger that closed least.
    ///
    /// Read them together while setting thresholds. A mean of 0.35 with a worst
    /// of 0.40 is a hand that closed evenly; a mean of 0.35 with a worst of 0.90
    /// is three fingers closed and one trailing, and `contactEnter` has to be
    /// chosen knowing which of those you actually make.
    private var gauges: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                distanceBar(tracker.distance, tinted: true, showThresholds: true)
                HStack {
                    Text(tracker.distance.map { String(format: "mean of %ld   d = %.3f", tracker.contributingFingers, $0) }
                         ?? "mean         d = —  (landmarks not confident)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(tracker.distance == nil ? Color.red : Color.primary)
                    Spacer()
                    Text(String(format: "%.0f fps", tracker.effectiveFPS))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                distribution
            }

            VStack(alignment: .leading, spacing: 4) {
                distanceBar(tracker.altDistance, tinted: false, showThresholds: false)
                Text(tracker.altDistance.map { String(format: "worst finger d = %.3f", $0) }
                     ?? "worst finger d = —  (landmarks not confident)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(tracker.altDistance == nil ? Color.red : Color.secondary)
            }
        }
    }

    /// Thresholds get set from here, not from the live number above it — that one
    /// repaints fifteen times a second and cannot be read, and a range eyeballed
    /// off it is a range built from whatever your eye happened to catch.
    ///
    /// Reset, hold the O for about fifteen seconds, read p95. Reset, relax your
    /// hand in frame for about fifteen seconds, read p05. `contactEnter` goes a
    /// little above the closed p95; `contactExit` a little below the open p05.
    /// Use the percentiles rather than min and max — one bad frame moves the
    /// extremes and shouldn't move your thresholds.
    private var distribution: some View {
        let d = tracker.stats.distance

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(d.count == 0
                     ? "no samples yet"
                     : String(format: "n=%ld   min %.2f   max %.2f", d.count, d.minimum, d.maximum))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Reset") { tracker.resetStats() }
                    .buttonStyle(.borderless)
                    .font(.caption2)
            }

            if d.count > 0 {
                Text(String(format: "p05 %.2f   med %.2f   p95 %.2f", d.p05, d.p50, d.p95))
                    .font(.system(.caption, design: .monospaced))
            }

            Text("Reset → hold the O ~15 s → read p95.  Reset → relax ~15 s → read p05.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

    /// The detector only ever sees one `Double?`. This is why it went nil, and
    /// which fingers are carrying it when it didn't.
    ///
    /// The tick on each bar is the floor that landmark has to clear. thumbTip
    /// and the scale pair are single points of failure — lose any of them and
    /// there is no measurement at all. The four fingertips are the forgiving
    /// part: each one that drops just leaves the average, and only when fewer
    /// than two survive does the frame go nil.
    private var landmarks: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("landmark confidence")
                .font(.caption.weight(.semibold))

            confidenceRow("thumbTip", tracker.confidence.thumbTip, floor: HandTracker.tipConfidence)

            Text("fingertips")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            confidenceRow("indexTip", tracker.confidence.indexTip, floor: HandTracker.tipConfidence)
            confidenceRow("middleTip", tracker.confidence.middleTip, floor: HandTracker.tipConfidence)
            confidenceRow("ringTip", tracker.confidence.ringTip, floor: HandTracker.tipConfidence)
            confidenceRow("littleTip", tracker.confidence.littleTip, floor: HandTracker.tipConfidence)

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

    /// Whether the aggregate holds up.
    ///
    /// The denominator is frames where the detector believed the hand was
    /// closed — loss while your hand is elsewhere is uninteresting. "worst" is
    /// the longest unbroken blackout, the figure `trackingGrace` has to absorb.
    ///
    /// Read "worst" as a lower bound, not a measurement: counting stops when the
    /// detector drops contact, which is precisely what happens once a blackout
    /// exceeds the grace. A value sitting at the grace means it hit the ceiling
    /// and the recording was terminated, not that the blackout ended there.
    private var occlusion: some View {
        let stats = tracker.stats
        let graceMs = config.trackingGrace * 1000
        let over = stats.longestDropout > config.trackingGrace
        let thin = stats.meanContributing > 0 && stats.meanContributing < 3

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("dropouts while closed")
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

            Text(String(format: "nil %5.1f%%   worst %4.0f ms",
                        stats.nilRate * 100, stats.longestDropout * 1000))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(over ? Color.red : Color.primary)

            Text(String(format: "avg %.2f of 4 fingertips contributing", stats.meanContributing))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(thin ? Color.orange : Color.primary)

            // Which of the three ways to lose a frame actually happened. The
            // fingertip column is the one the aggregate can fix; the other two
            // take every finger down at once and need a structural answer.
            Text(String(format: "  scale %ld   thumb %ld   fingers %ld",
                        stats.nilFromScale, stats.nilFromThumb, stats.nilFromFingers))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(String(format: "red above the %.0f ms grace — that dictation would have been cut. Orange means the average is running on fewer fingers than the gesture implies.", graceMs))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Hold the O for 20–30 s the way you actually would — at your real desk height, turning your hand as you talk — then read both rows. Reset between trials.")
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
