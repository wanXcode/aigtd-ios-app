import SwiftUI

enum AIGTDCardKind: Sendable {
    case standard
    case task
    case action
    case settings

    var backgroundToken: AIGTDAdaptiveColor {
        switch self {
        case .standard, .settings:
            AIGTDColor.surfaceToken
        case .task:
            AIGTDAdaptiveColor(
                light: AIGTDRGBA(red: 0.95, green: 0.98, blue: 1),
                dark: AIGTDRGBA(red: 0.16, green: 0.21, blue: 0.26)
            )
        case .action:
            AIGTDRGBA(red: 0.94, green: 0.97, blue: 1).adaptive(
                dark: AIGTDRGBA(red: 0.15, green: 0.20, blue: 0.27)
            )
        }
    }

    var borderToken: AIGTDAdaptiveColor {
        switch self {
        case .standard, .settings:
            AIGTDColor.dividerToken
        case .task, .action:
            AIGTDAdaptiveColor(
                light: AIGTDRGBA(red: 0.68, green: 0.83, blue: 1),
                dark: AIGTDRGBA(red: 0.24, green: 0.47, blue: 0.72)
            )
        }
    }
}

private extension AIGTDRGBA {
    func adaptive(dark: AIGTDRGBA) -> AIGTDAdaptiveColor {
        AIGTDAdaptiveColor(light: self, dark: dark)
    }
}

struct AIGTDCard<Content: View>: View {
    let kind: AIGTDCardKind
    let accessibility: AIGTDAccessibilityDescriptor?
    @ViewBuilder let content: Content

    init(
        kind: AIGTDCardKind = .standard,
        accessibility: AIGTDAccessibilityDescriptor? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.kind = kind
        self.accessibility = accessibility
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AIGTDLayout.cardPadding)
            .background(kind.backgroundToken.color)
            .clipShape(RoundedRectangle(cornerRadius: AIGTDLayout.cardCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: AIGTDLayout.cardCornerRadius)
                    .stroke(kind.borderToken.color.opacity(0.55), lineWidth: 1)
            }
            .shadow(color: AIGTDColor.warmCharcoal.color.opacity(0.05), radius: 10, y: 4)
            .modifier(AIGTDOptionalVoiceOverModifier(descriptor: accessibility))
    }
}

enum AIGTDBubbleRole: Sendable {
    case user
    case assistant

    var accessibilityName: String {
        switch self {
        case .user: "你"
        case .assistant: "小满"
        }
    }
}

struct AIGTDBubble<Content: View>: View {
    let role: AIGTDBubbleRole
    let accessibilityText: String?
    @ViewBuilder let content: Content

    init(
        role: AIGTDBubbleRole,
        accessibilityText: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.role = role
        self.accessibilityText = accessibilityText
        self.content = content()
    }

    var body: some View {
        content
            .foregroundStyle(
                role == .user
                    ? AIGTDColor.userBubbleTextToken.color
                    : AIGTDColor.primaryText
            )
            .padding(.horizontal, AIGTDLayout.bubbleHorizontalPadding)
            .padding(.vertical, AIGTDLayout.bubbleVerticalPadding)
            .background(
                role == .user
                    ? AIGTDColor.userBubbleToken.color
                    : AIGTDColor.assistantBubbleToken.color
            )
            .clipShape(RoundedRectangle(cornerRadius: AIGTDLayout.bubbleCornerRadius))
            .modifier(
                AIGTDOptionalVoiceOverModifier(
                    descriptor: accessibilityText.map {
                        AIGTDAccessibilityDescriptor(
                            label: role.accessibilityName,
                            value: $0
                        )
                    }
                )
            )
    }
}

enum AIGTDStatus: String, CaseIterable, Sendable {
    case understanding
    case waitingForConfirmation
    case processing
    case completed
    case partiallyCompleted
    case failed
    case restored
    case cancelled

    var title: String {
        switch self {
        case .understanding: "正在理解"
        case .waitingForConfirmation: "待确认"
        case .processing: "处理中"
        case .completed: "已完成"
        case .partiallyCompleted: "部分完成"
        case .failed: "未完成"
        case .restored: "已恢复"
        case .cancelled: "已取消"
        }
    }

    var systemImage: String {
        switch self {
        case .understanding: "ellipsis"
        case .waitingForConfirmation: "questionmark.circle.fill"
        case .processing: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle.fill"
        case .partiallyCompleted: "exclamationmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .restored: "arrow.uturn.backward.circle.fill"
        case .cancelled: "minus.circle.fill"
        }
    }

    var tintToken: AIGTDAdaptiveColor {
        switch self {
        case .understanding:
            AIGTDColor.infoToken
        case .waitingForConfirmation, .processing, .partiallyCompleted:
            AIGTDColor.pendingToken
        case .completed, .restored:
            AIGTDColor.successToken
        case .failed:
            AIGTDColor.failureToken
        case .cancelled:
            AIGTDColor.secondaryTextToken
        }
    }

    var accessibilityDescriptor: AIGTDAccessibilityDescriptor {
        AIGTDAccessibilityDescriptor(label: "状态", value: title)
    }
}

struct AIGTDStatusPill: View {
    let status: AIGTDStatus

    var body: some View {
        Label(status.title, systemImage: status.systemImage)
            .font(AIGTDTextStyle.metadata.font.weight(.semibold))
            .foregroundStyle(status.tintToken.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(status.tintToken.color.opacity(0.12))
            .clipShape(Capsule())
            .aigtdVoiceOver(status.accessibilityDescriptor)
    }
}

enum AIGTDActionButtonKind: Sendable {
    case primary
    case secondary
    case quiet
    case destructive
}

struct AIGTDActionButton<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled

    let kind: AIGTDActionButtonKind
    let accessibility: AIGTDAccessibilityDescriptor?
    let action: () -> Void
    @ViewBuilder let label: Label

    init(
        kind: AIGTDActionButtonKind = .primary,
        accessibility: AIGTDAccessibilityDescriptor? = nil,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.kind = kind
        self.accessibility = accessibility
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            label
                .font(AIGTDTextStyle.action.font)
                .foregroundStyle(foregroundColor)
                .frame(minHeight: AIGTDLayout.minimumTapTarget)
                .padding(.horizontal, 15)
                .background(backgroundColor)
                .clipShape(Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .disabled(!isEnabled)
        .modifier(AIGTDOptionalVoiceOverModifier(descriptor: accessibility))
    }

    private var foregroundColor: Color {
        switch kind {
        case .primary, .destructive:
            AIGTDColor.userBubbleTextToken.color
        case .secondary:
            AIGTDColor.brand
        case .quiet:
            AIGTDColor.secondaryText
        }
    }

    private var backgroundColor: Color {
        switch kind {
        case .primary:
            AIGTDColor.brand
        case .secondary:
            AIGTDColor.infoToken.color.opacity(0.12)
        case .quiet:
            .clear
        case .destructive:
            AIGTDColor.failureToken.color
        }
    }
}

struct AIGTDIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let accessibilityHint: String?
    let action: () -> Void

    init(
        systemImage: String,
        accessibilityLabel: String,
        accessibilityHint: String? = nil,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AIGTDColor.brand)
                .aigtdMinimumTapTarget()
        }
        .buttonStyle(.plain)
        .aigtdVoiceOver(
            AIGTDAccessibilityDescriptor(
                label: accessibilityLabel,
                hint: accessibilityHint
            )
        )
    }
}

private struct AIGTDOptionalVoiceOverModifier: ViewModifier {
    let descriptor: AIGTDAccessibilityDescriptor?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let descriptor {
            content.aigtdVoiceOver(descriptor)
        } else {
            content
        }
    }
}
