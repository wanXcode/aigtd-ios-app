import SwiftUI
import UIKit

struct AIGTDRGBA: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let opacity: Double

    init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    @MainActor
    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: opacity)
    }

    @MainActor
    var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: opacity)
    }
}

struct AIGTDAdaptiveColor: Equatable, Sendable {
    let light: AIGTDRGBA
    let dark: AIGTDRGBA

    func resolved(for style: UIUserInterfaceStyle) -> AIGTDRGBA {
        style == .dark ? dark : light
    }

    @MainActor
    var uiColor: UIColor {
        UIColor { traits in
            resolved(for: traits.userInterfaceStyle).uiColor
        }
    }

    @MainActor
    var color: Color {
        Color(uiColor: uiColor)
    }
}

enum AIGTDColor {
    // Brand anchors. Screens should prefer the semantic roles below.
    static let warmWhite = AIGTDRGBA(red: 0.98, green: 0.97, blue: 0.94)
    static let brandBlue = AIGTDRGBA(red: 0.05, green: 0.52, blue: 0.96)
    static let xiaomanApricot = AIGTDRGBA(red: 0.98, green: 0.63, blue: 0.31)
    static let warmCharcoal = AIGTDRGBA(red: 0.14, green: 0.13, blue: 0.12)

    static let backgroundToken = AIGTDAdaptiveColor(
        light: warmWhite,
        dark: warmCharcoal
    )
    static let surfaceToken = AIGTDAdaptiveColor(
        light: AIGTDRGBA(red: 1, green: 0.995, blue: 0.98),
        dark: AIGTDRGBA(red: 0.19, green: 0.18, blue: 0.16)
    )
    static let raisedSurfaceToken = AIGTDAdaptiveColor(
        light: AIGTDRGBA(red: 1, green: 1, blue: 1),
        dark: AIGTDRGBA(red: 0.23, green: 0.21, blue: 0.19)
    )
    static let primaryTextToken = AIGTDAdaptiveColor(
        light: AIGTDRGBA(red: 0.14, green: 0.13, blue: 0.12),
        dark: AIGTDRGBA(red: 0.97, green: 0.95, blue: 0.91)
    )
    static let secondaryTextToken = AIGTDAdaptiveColor(
        light: AIGTDRGBA(red: 0.40, green: 0.38, blue: 0.35),
        dark: AIGTDRGBA(red: 0.76, green: 0.72, blue: 0.67)
    )
    static let subtleTextToken = AIGTDAdaptiveColor(
        light: AIGTDRGBA(red: 0.53, green: 0.50, blue: 0.46),
        dark: AIGTDRGBA(red: 0.66, green: 0.62, blue: 0.58)
    )
    static let dividerToken = AIGTDAdaptiveColor(
        light: AIGTDRGBA(red: 0.88, green: 0.85, blue: 0.80),
        dark: AIGTDRGBA(red: 0.34, green: 0.31, blue: 0.28)
    )
    static let assistantBubbleToken = AIGTDAdaptiveColor(
        light: AIGTDRGBA(red: 1, green: 0.995, blue: 0.98),
        dark: AIGTDRGBA(red: 0.21, green: 0.19, blue: 0.17)
    )
    static let userBubbleToken = AIGTDAdaptiveColor(
        light: brandBlue,
        dark: AIGTDRGBA(red: 0.10, green: 0.46, blue: 0.84)
    )
    static let userBubbleTextToken = AIGTDAdaptiveColor(
        light: AIGTDRGBA(red: 1, green: 1, blue: 1),
        dark: AIGTDRGBA(red: 1, green: 1, blue: 1)
    )
    static let assistantAccentToken = AIGTDAdaptiveColor(
        light: xiaomanApricot,
        dark: AIGTDRGBA(red: 1, green: 0.68, blue: 0.39)
    )
    static let infoToken = AIGTDAdaptiveColor(
        light: brandBlue,
        dark: AIGTDRGBA(red: 0.35, green: 0.68, blue: 1)
    )
    static let pendingToken = AIGTDAdaptiveColor(
        light: AIGTDRGBA(red: 0.93, green: 0.48, blue: 0.17),
        dark: AIGTDRGBA(red: 1, green: 0.65, blue: 0.31)
    )
    static let successToken = AIGTDAdaptiveColor(
        light: AIGTDRGBA(red: 0.16, green: 0.58, blue: 0.34),
        dark: AIGTDRGBA(red: 0.35, green: 0.78, blue: 0.51)
    )
    static let failureToken = AIGTDAdaptiveColor(
        light: AIGTDRGBA(red: 0.82, green: 0.22, blue: 0.23),
        dark: AIGTDRGBA(red: 1, green: 0.43, blue: 0.42)
    )

    @MainActor static var background: Color { backgroundToken.color }
    @MainActor static var surface: Color { surfaceToken.color }
    @MainActor static var raisedSurface: Color { raisedSurfaceToken.color }
    @MainActor static var primaryText: Color { primaryTextToken.color }
    @MainActor static var secondaryText: Color { secondaryTextToken.color }
    @MainActor static var subtleText: Color { subtleTextToken.color }
    @MainActor static var divider: Color { dividerToken.color }
    @MainActor static var brand: Color { brandBlue.color }
    @MainActor static var assistantAccent: Color { assistantAccentToken.color }
}

enum AIGTDLayout {
    static let minimumTapTarget: CGFloat = 44
    static let compactSpacing: CGFloat = 6
    static let itemSpacing: CGFloat = 10
    static let contentSpacing: CGFloat = 16
    static let sectionSpacing: CGFloat = 24
    static let horizontalPagePadding: CGFloat = 18
    static let cardPadding: CGFloat = 16
    static let compactCardPadding: CGFloat = 12
    static let bubbleHorizontalPadding: CGFloat = 15
    static let bubbleVerticalPadding: CGFloat = 11
    static let cardCornerRadius: CGFloat = 20
    static let bubbleCornerRadius: CGFloat = 19
    static let pillCornerRadius: CGFloat = 999
}

enum AIGTDTextStyle: CaseIterable, Sendable {
    case screenTitle
    case cardTitle
    case body
    case callout
    case metadata
    case action

    var usesSemanticTextStyle: Bool { true }

    @MainActor
    var font: Font {
        switch self {
        case .screenTitle:
            .system(.title2, design: .rounded, weight: .semibold)
        case .cardTitle:
            .system(.headline, design: .rounded, weight: .semibold)
        case .body:
            .system(.body, design: .rounded)
        case .callout:
            .system(.callout, design: .rounded)
        case .metadata:
            .system(.footnote, design: .rounded)
        case .action:
            .system(.body, design: .rounded, weight: .semibold)
        }
    }
}

enum AIGTDMotionTransition: Sendable {
    case stateChange
    case insertion
    case focus
}

struct AIGTDMotionSpec: Equatable, Sendable {
    let duration: Double
    let includesMovement: Bool
}

enum AIGTDMotion {
    static func spec(
        for transition: AIGTDMotionTransition = .stateChange,
        reduceMotion: Bool
    ) -> AIGTDMotionSpec {
        if reduceMotion {
            return AIGTDMotionSpec(duration: 0.12, includesMovement: false)
        }

        let duration: Double = switch transition {
        case .stateChange: 0.22
        case .insertion: 0.20
        case .focus: 0.18
        }
        return AIGTDMotionSpec(duration: duration, includesMovement: true)
    }

    @MainActor
    static func animation(
        for transition: AIGTDMotionTransition = .stateChange,
        reduceMotion: Bool
    ) -> Animation {
        let spec = spec(for: transition, reduceMotion: reduceMotion)
        return reduceMotion
            ? .linear(duration: spec.duration)
            : .easeInOut(duration: spec.duration)
    }
}

struct AIGTDAccessibilityDescriptor: Equatable, Sendable {
    let label: String
    let value: String?
    let hint: String?

    init(label: String, value: String? = nil, hint: String? = nil) {
        self.label = label
        self.value = value
        self.hint = hint
    }
}

private struct AIGTDMinimumTapTargetModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(
                minWidth: AIGTDLayout.minimumTapTarget,
                minHeight: AIGTDLayout.minimumTapTarget
            )
            .contentShape(Rectangle())
    }
}

private struct AIGTDReadableTextModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AIGTDVoiceOverModifier: ViewModifier {
    let descriptor: AIGTDAccessibilityDescriptor
    let combineChildren: Bool

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: combineChildren ? .combine : .contain)
            .accessibilityLabel(Text(descriptor.label))
            .aigtdAccessibilityValue(descriptor.value)
            .aigtdAccessibilityHint(descriptor.hint)
    }
}

private struct AIGTDStateTransitionModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let transition: AIGTDMotionTransition
    let value: Value

    func body(content: Content) -> some View {
        content.animation(
            AIGTDMotion.animation(for: transition, reduceMotion: reduceMotion),
            value: value
        )
    }
}

extension View {
    func aigtdMinimumTapTarget() -> some View {
        modifier(AIGTDMinimumTapTargetModifier())
    }

    func aigtdReadableText() -> some View {
        modifier(AIGTDReadableTextModifier())
    }

    func aigtdVoiceOver(
        _ descriptor: AIGTDAccessibilityDescriptor,
        combineChildren: Bool = true
    ) -> some View {
        modifier(
            AIGTDVoiceOverModifier(
                descriptor: descriptor,
                combineChildren: combineChildren
            )
        )
    }

    func aigtdStateTransition<Value: Equatable>(
        _ transition: AIGTDMotionTransition = .stateChange,
        value: Value
    ) -> some View {
        modifier(AIGTDStateTransitionModifier(transition: transition, value: value))
    }

    @ViewBuilder
    fileprivate func aigtdAccessibilityValue(_ value: String?) -> some View {
        if let value, !value.isEmpty {
            accessibilityValue(Text(value))
        } else {
            self
        }
    }

    @ViewBuilder
    fileprivate func aigtdAccessibilityHint(_ hint: String?) -> some View {
        if let hint, !hint.isEmpty {
            accessibilityHint(Text(hint))
        } else {
            self
        }
    }
}
