import SwiftUI

enum VoiceGesturePolicy {
    /// The text composer needs a deliberate hold so an ordinary tap never
    /// competes with keyboard focus.
    static let composerHoldDuration: TimeInterval = 1.0
    static let dedicatedVoiceHoldDuration: TimeInterval = 0.16
    static let maximumHoldMovement: CGFloat = 18
}

enum VoiceCaptureLayout {
    static func timelineReservationHeight(
        dynamicTypeSize: DynamicTypeSize,
        compactHeight: Bool
    ) -> CGFloat {
        if compactHeight { return 260 }
        return dynamicTypeSize.isAccessibilitySize ? 390 : 340
    }

    static func stageHeight(availableHeight: CGFloat, dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        if availableHeight < 600 {
            return min(max(availableHeight * 0.64, 300), 390)
        }
        if dynamicTypeSize.isAccessibilitySize {
            return min(max(availableHeight * 0.58, 440), 560)
        }
        return min(max(availableHeight * 0.52, 400), 500)
    }

    static func bluePanelHeight(availableHeight: CGFloat) -> CGFloat {
        if availableHeight < 600 { return 150 }
        return min(max(availableHeight * 0.22, 170), 230)
    }

    static func transcriptHeight(availableHeight: CGFloat, dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        if availableHeight < 600 { return 84 }
        return dynamicTypeSize.isAccessibilitySize ? 154 : 118
    }
}

struct VoiceCaptureOverlay: View {
    @ObservedObject var state: VoiceInteractionState
    @ObservedObject private var presentation: VoiceCapturePresentationState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(state: VoiceInteractionState) {
        _state = ObservedObject(wrappedValue: state)
        _presentation = ObservedObject(wrappedValue: state.presentation)
    }

    var body: some View {
        GeometryReader { proxy in
            let availableHeight = proxy.size.height
            let stageHeight = VoiceCaptureLayout.stageHeight(
                availableHeight: availableHeight,
                dynamicTypeSize: dynamicTypeSize
            )
            let transcriptHeight = VoiceCaptureLayout.transcriptHeight(
                availableHeight: availableHeight,
                dynamicTypeSize: dynamicTypeSize
            )

            ZStack(alignment: .bottom) {
                backgroundWash
                blueVoicePanel(height: VoiceCaptureLayout.bluePanelHeight(availableHeight: availableHeight))

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    voiceStage(height: stageHeight, transcriptHeight: transcriptHeight)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: state.phase)
        .sensoryFeedback(.impact(weight: .light), trigger: state.phase == .recording)
        .sensoryFeedback(.warning, trigger: state.phase == .cancelling)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("语音输入，\(instructionText)，已录制 \(state.formattedDuration)")
        .accessibilityAction(named: "结束录音并转成文字") {
            Task { await state.releaseCapture() }
        }
        .accessibilityAction(named: "取消语音输入") {
            state.cancelCapture()
        }
    }

    private func voiceStage(height: CGFloat, transcriptHeight: CGFloat) -> some View {
        VStack(spacing: 10) {
            Color.clear
                .frame(height: 60)

            liveTranscriptView(height: transcriptHeight)

            Text(instructionText)
                .font(.title3.weight(.semibold))
                .foregroundStyle(instructionColor)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .padding(.horizontal, 32)

            Text(state.formattedDuration)
                .font(.system(.footnote, design: .rounded, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer(minLength: 6)

            VoiceWaveform(
                meter: state.audioMeter,
                isActive: state.phase == .recording,
                isCancelling: state.isCancellationArmed,
                reduceMotion: reduceMotion
            )
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }

    private func liveTranscriptView(height: CGFloat) -> some View {
        let stable = presentation.transcript.stable.trimmingCharacters(in: .whitespacesAndNewlines)
        let partial = presentation.transcript.partial.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = presentation.transcript.live.trimmingCharacters(in: .whitespacesAndNewlines)

        return ScrollView {
            transcriptText(stable: stable, partial: partial)
                .font(.title3.weight(transcript.isEmpty ? .regular : .medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .contentTransition(.interpolate)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollIndicators(.hidden)
        .frame(maxWidth: 560, minHeight: height, maxHeight: height)
        .padding(.horizontal, 36)
        .accessibilityLabel(transcript.isEmpty ? "正在等待语音" : "已识别：\(transcript)")
    }

    private func transcriptText(stable: String, partial: String) -> Text {
        if stable.isEmpty && partial.isEmpty {
            return Text("正在听…")
                .foregroundStyle(.secondary)
        }
        if stable.isEmpty {
            return Text(partial)
                .foregroundStyle(.primary.opacity(0.72))
        }
        if partial.isEmpty {
            return Text(stable)
                .foregroundStyle(.primary)
        }

        let separator = needsTranscriptSeparator(after: stable) ? "，" : ""
        return Text(stable + separator)
            .foregroundStyle(.primary)
            + Text(partial)
            .foregroundStyle(.primary.opacity(0.68))
    }

    private func needsTranscriptSeparator(after text: String) -> Bool {
        guard let last = text.last else { return false }
        return "，。！？；：,.!?;:".contains(last) == false
    }

    private var instructionText: String {
        switch state.phase {
        case .cancelling:
            return "松手取消"
        case .finalizing:
            return "正在转成文字…"
        case .requestingPermission, .starting:
            return "正在准备语音输入…"
        case .recording:
            return "松手转文字，上滑取消"
        case .idle, .draftReady, .failed:
            return "松手转文字，上滑取消"
        }
    }

    private var instructionColor: Color {
        state.isCancellationArmed ? Color.red.opacity(0.96) : Color.blue.opacity(0.96)
    }

    private var backgroundWash: some View {
        let background = Color(uiColor: .systemBackground)
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: 0.18),
                .init(color: background.opacity(0.18), location: 0.34),
                .init(color: background.opacity(0.62), location: 0.5),
                .init(color: background.opacity(0.9), location: 0.64),
                .init(color: background.opacity(0.99), location: 0.76),
                .init(color: background, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func blueVoicePanel(height: CGFloat) -> some View {
        ZStack {
            VoiceBluePanelShape()
                .fill(Color.blue.opacity(colorScheme == .dark ? 0.18 : 0.1))
                .offset(y: -6)

            VoiceBluePanelShape()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.0, green: 0.4, blue: 1.0),
                            Color(red: 0.36, green: 0.64, blue: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .frame(height: height)
    }
}

private struct VoiceBluePanelShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + 18))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + 18),
            control: CGPoint(x: rect.midX, y: rect.minY - 10)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct VoiceWaveform: View {
    @ObservedObject var meter: VoiceAudioMeterState
    let isActive: Bool
    let isCancelling: Bool
    let reduceMotion: Bool

    var body: some View {
        Canvas { context, size in
            let count = 31
            let barWidth: CGFloat = 3
            let spacing = max(3, (size.width - CGFloat(count) * barWidth) / CGFloat(count - 1))
            for index in 0..<count {
                let height = barHeight(at: index, level: meter.level)
                let x = CGFloat(index) * (barWidth + spacing)
                let rect = CGRect(
                    x: x,
                    y: (size.height - height) / 2,
                    width: barWidth,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(.white.opacity(isCancelling ? 0.72 : 0.94))
                )
            }
        }
        .frame(maxWidth: 230)
        .frame(height: 54)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: meter.level)
        .accessibilityHidden(true)
    }

    private func barHeight(at index: Int, level: Double) -> CGFloat {
        guard isActive else { return index.isMultiple(of: 5) ? 10 : 4 }
        let centerDistance = abs(Double(index) - 15) / 15
        let envelope = 1 - centerDistance * 0.54
        let texture = 0.62 + 0.38 * abs(sin(Double(index) * 1.73))
        let effectiveLevel = reduceMotion ? min(level, 0.45) : level
        return 4 + CGFloat((5 + effectiveLevel * 38 * texture) * envelope)
    }
}

private struct VoiceHoldToTalkModifier: ViewModifier {
    @ObservedObject var state: VoiceInteractionState
    let configuration: VoiceTranscriptionConfiguration?
    @Binding var draft: String
    let insertionUTF16Offset: Int?
    let isEnabled: Bool
    let onUnavailable: () -> Void

    @State private var didBeginGesture = false

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(holdGesture)
            .accessibilityAction(named: "开始或结束录音") {
                guard isEnabled else { return }
                guard let configuration else {
                    onUnavailable()
                    return
                }
                Task {
                    await state.toggleAccessibleCapture(
                        configuration: configuration,
                        currentDraft: draft,
                        insertionUTF16Offset: insertionUTF16Offset
                    )
                }
            }
    }

    private var holdGesture: some Gesture {
        LongPressGesture(
            minimumDuration: VoiceGesturePolicy.dedicatedVoiceHoldDuration,
            maximumDistance: VoiceGesturePolicy.maximumHoldMovement
        )
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                switch value {
                case .first(true):
                    beginGestureIfNeeded()
                case let .second(true, drag):
                    beginGestureIfNeeded()
                    if let drag {
                        state.updateDrag(verticalTranslation: drag.translation.height)
                    }
                default:
                    break
                }
            }
            .onEnded { value in
                if case let .second(true, drag) = value, let drag {
                    state.updateDrag(verticalTranslation: drag.translation.height)
                }
                let shouldReleaseCapture = didBeginGesture
                didBeginGesture = false
                guard shouldReleaseCapture else { return }
                Task {
                    await state.releaseCapture()
                }
            }
    }

    private func beginGestureIfNeeded() {
        guard isEnabled, didBeginGesture == false else { return }
        didBeginGesture = true
        guard let configuration else {
            onUnavailable()
            return
        }
        Task {
            await state.beginCapture(
                configuration: configuration,
                currentDraft: draft,
                insertionUTF16Offset: insertionUTF16Offset
            )
        }
    }
}

private struct VoiceTapOrHoldModifier: ViewModifier {
    @ObservedObject var state: VoiceInteractionState
    let configuration: VoiceTranscriptionConfiguration?
    @Binding var draft: String
    let insertionUTF16Offset: Int?
    let isEnabled: Bool
    let onTap: () -> Void
    let onUnavailable: () -> Void

    @State private var didBeginGesture = false
    @State private var suppressTap = false

    func body(content: Content) -> some View {
        content
            .onTapGesture {
                guard didBeginGesture == false, suppressTap == false else { return }
                onTap()
            }
            .simultaneousGesture(holdGesture)
    }

    private var holdGesture: some Gesture {
        LongPressGesture(
            minimumDuration: VoiceGesturePolicy.composerHoldDuration,
            maximumDistance: VoiceGesturePolicy.maximumHoldMovement
        )
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                handleHoldChanged(value)
            }
            .onEnded { value in
                handleHoldEnded(value)
            }
    }

    private func handleHoldChanged(
        _ value: SequenceGesture<LongPressGesture, DragGesture>.Value
    ) {
        switch value {
        case .first(true):
            beginGestureIfNeeded()
        case let .second(true, drag):
            beginGestureIfNeeded()
            if let drag {
                state.updateDrag(verticalTranslation: drag.translation.height)
            }
        default:
            break
        }
    }

    private func handleHoldEnded(
        _ value: SequenceGesture<LongPressGesture, DragGesture>.Value
    ) {
        if case let .second(true, drag) = value, let drag {
            state.updateDrag(verticalTranslation: drag.translation.height)
        }
        let shouldReleaseCapture = didBeginGesture
        didBeginGesture = false
        guard shouldReleaseCapture else { return }
        Task {
            await state.releaseCapture()
            try? await Task.sleep(for: .milliseconds(120))
            suppressTap = false
        }
    }

    private func beginGestureIfNeeded() {
        guard isEnabled, didBeginGesture == false else { return }
        didBeginGesture = true
        suppressTap = true
        guard let configuration else {
            onUnavailable()
            return
        }
        Task {
            await state.beginCapture(
                configuration: configuration,
                currentDraft: draft,
                insertionUTF16Offset: insertionUTF16Offset
            )
        }
    }
}

extension View {
    /// Adds DingTalk-style hold-to-talk behavior to a dedicated voice surface.
    func voiceHoldToTalk(
        state: VoiceInteractionState,
        configuration: VoiceTranscriptionConfiguration?,
        draft: Binding<String>,
        insertionUTF16Offset: Int? = nil,
        isEnabled: Bool = true,
        onUnavailable: @escaping () -> Void
    ) -> some View {
        modifier(
            VoiceHoldToTalkModifier(
                state: state,
                configuration: configuration,
                draft: draft,
                insertionUTF16Offset: insertionUTF16Offset,
                isEnabled: isEnabled,
                onUnavailable: onUnavailable
            )
        )
    }

    /// Arbitrates an empty composer tap against hold-to-talk without allowing
    /// UIKit's text loupe to compete for the same touch sequence.
    func voiceTapOrHold(
        state: VoiceInteractionState,
        configuration: VoiceTranscriptionConfiguration?,
        draft: Binding<String>,
        insertionUTF16Offset: Int? = nil,
        isEnabled: Bool = true,
        onTap: @escaping () -> Void,
        onUnavailable: @escaping () -> Void
    ) -> some View {
        modifier(
            VoiceTapOrHoldModifier(
                state: state,
                configuration: configuration,
                draft: draft,
                insertionUTF16Offset: insertionUTF16Offset,
                isEnabled: isEnabled,
                onTap: onTap,
                onUnavailable: onUnavailable
            )
        )
    }
}
