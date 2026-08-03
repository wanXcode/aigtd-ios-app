import SwiftUI

struct VoiceCaptureOverlay: View {
    @ObservedObject var state: VoiceInteractionState
    let onFinish: () -> Void
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 24)

            transcriptView

            HStack(spacing: 10) {
                VoiceWaveform(isActive: state.phase == .recording)
                Text(state.formattedDuration)
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                VoiceWaveform(isActive: state.phase == .recording)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("录音时长 \(state.formattedDuration)")

            Text(state.releaseInstruction)
                .font(.headline)
                .foregroundStyle(state.isCancellationArmed ? Color.red : Color.primary)
                .contentTransition(.opacity)

            HStack(spacing: 14) {
                Button("取消", action: onCancel)
                    .buttonStyle(VoiceOverlaySecondaryButtonStyle())
                    .accessibilityHint("取消本次录音并保留原来的输入内容")

                Button("结束录音", action: onFinish)
                    .buttonStyle(VoiceOverlayPrimaryButtonStyle())
                    .accessibilityHint("把识别文字放入输入框，不会自动发送")
            }
            .accessibilityElement(children: .contain)

            Spacer(minLength: 18)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, minHeight: 250)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .strokeBorder(state.isCancellationArmed ? Color.red.opacity(0.35) : Color.blue.opacity(0.16))
        }
        .shadow(color: .black.opacity(0.12), radius: 28, y: 10)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: state.phase)
        .sensoryFeedback(.impact(weight: .light), trigger: state.phase == .recording)
        .sensoryFeedback(.warning, trigger: state.phase == .cancelling)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("语音输入")
    }

    @ViewBuilder
    private var transcriptView: some View {
        let text = state.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(spacing: 8) {
            Text(state.statusText)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(state.isCancellationArmed ? Color.red : Color.secondary)

            Text(text.isEmpty ? "说出你想记下或调整的事情" : text)
                .font(.title3)
                .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 58)
                .contentTransition(.interpolate)
                .accessibilityLabel(text.isEmpty ? "等待说话" : "已识别：\(text)")
        }
    }
}

private struct VoiceWaveform: View {
    let isActive: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<7, id: \.self) { index in
                Capsule()
                    .fill(isActive ? Color.blue.opacity(0.78) : Color.secondary.opacity(0.3))
                    .frame(width: 3, height: barHeight(at: index))
            }
        }
        .frame(height: 24)
        .accessibilityHidden(true)
    }

    private func barHeight(at index: Int) -> CGFloat {
        let heights: [CGFloat] = [7, 13, 19, 24, 19, 13, 7]
        return isActive ? heights[index] : 5
    }
}

private struct VoiceOverlayPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Color.blue.opacity(configuration.isPressed ? 0.72 : 0.94))
            .clipShape(Capsule())
    }
}

private struct VoiceOverlaySecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Color.secondary.opacity(configuration.isPressed ? 0.16 : 0.09))
            .clipShape(Capsule())
    }
}

private struct VoiceHoldToTalkModifier: ViewModifier {
    @ObservedObject var state: VoiceInteractionState
    let configuration: VoiceTranscriptionConfiguration?
    @Binding var draft: String
    let insertionUTF16Offset: Int?
    let onUnavailable: () -> Void

    @State private var didBeginGesture = false

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(holdGesture)
            .accessibilityAction(named: "开始或结束录音") {
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
        LongPressGesture(minimumDuration: 0.2, maximumDistance: 24)
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
        guard didBeginGesture == false else { return }
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

extension View {
    /// Adds DingTalk-style hold-to-talk behavior to a dedicated voice surface.
    func voiceHoldToTalk(
        state: VoiceInteractionState,
        configuration: VoiceTranscriptionConfiguration?,
        draft: Binding<String>,
        insertionUTF16Offset: Int? = nil,
        onUnavailable: @escaping () -> Void
    ) -> some View {
        modifier(
            VoiceHoldToTalkModifier(
                state: state,
                configuration: configuration,
                draft: draft,
                insertionUTF16Offset: insertionUTF16Offset,
                onUnavailable: onUnavailable
            )
        )
    }
}
