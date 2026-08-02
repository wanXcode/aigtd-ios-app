import XCTest
import UIKit
@testable import AIGTDReminders

final class AIGTDDesignSystemTests: XCTestCase {
    func testBrandAnchorsMatchTheWarmProductDirection() {
        XCTAssertEqual(
            AIGTDColor.warmWhite,
            AIGTDRGBA(red: 0.98, green: 0.97, blue: 0.94)
        )
        XCTAssertEqual(
            AIGTDColor.brandBlue,
            AIGTDRGBA(red: 0.05, green: 0.52, blue: 0.96)
        )
        XCTAssertEqual(
            AIGTDColor.xiaomanApricot,
            AIGTDRGBA(red: 0.98, green: 0.63, blue: 0.31)
        )
        XCTAssertEqual(
            AIGTDColor.warmCharcoal,
            AIGTDRGBA(red: 0.14, green: 0.13, blue: 0.12)
        )
    }

    func testAdaptiveColorsResolveForLightAndDarkAppearances() {
        XCTAssertEqual(
            AIGTDColor.backgroundToken.resolved(for: .light),
            AIGTDColor.warmWhite
        )
        XCTAssertEqual(
            AIGTDColor.backgroundToken.resolved(for: .dark),
            AIGTDColor.warmCharcoal
        )
        XCTAssertNotEqual(
            AIGTDColor.surfaceToken.resolved(for: .light),
            AIGTDColor.surfaceToken.resolved(for: .dark)
        )
    }

    func testPrimaryTextMaintainsReadableContrastOnBackground() {
        let lightContrast = contrastRatio(
            AIGTDColor.primaryTextToken.resolved(for: .light),
            AIGTDColor.backgroundToken.resolved(for: .light)
        )
        let darkContrast = contrastRatio(
            AIGTDColor.primaryTextToken.resolved(for: .dark),
            AIGTDColor.backgroundToken.resolved(for: .dark)
        )

        XCTAssertGreaterThanOrEqual(lightContrast, 7)
        XCTAssertGreaterThanOrEqual(darkContrast, 7)
    }

    func testTapTargetsMeetAppleMinimumSize() {
        XCTAssertGreaterThanOrEqual(AIGTDLayout.minimumTapTarget, 44)
    }

    func testMotionUsesShortTransitionsAndRemovesMovementWhenReduced() {
        for transition in [
            AIGTDMotionTransition.stateChange,
            .insertion,
            .focus
        ] {
            let regular = AIGTDMotion.spec(for: transition, reduceMotion: false)
            let reduced = AIGTDMotion.spec(for: transition, reduceMotion: true)

            XCTAssertTrue((0.18...0.24).contains(regular.duration))
            XCTAssertTrue(regular.includesMovement)
            XCTAssertLessThan(reduced.duration, regular.duration)
            XCTAssertFalse(reduced.includesMovement)
        }
    }

    func testTypographyUsesSemanticStylesForDynamicType() {
        XCTAssertFalse(AIGTDTextStyle.allCases.isEmpty)
        XCTAssertTrue(AIGTDTextStyle.allCases.allSatisfy(\.usesSemanticTextStyle))
    }

    func testEveryStatusHasTextIconAndVoiceOverValue() {
        for status in AIGTDStatus.allCases {
            XCTAssertFalse(status.title.isEmpty)
            XCTAssertFalse(status.systemImage.isEmpty)
            XCTAssertEqual(status.accessibilityDescriptor.label, "状态")
            XCTAssertEqual(status.accessibilityDescriptor.value, status.title)
        }
    }

    func testVoiceOverDescriptorCarriesActionContext() {
        let descriptor = AIGTDAccessibilityDescriptor(
            label: "调整任务",
            value: "开会，明天下午 3 点",
            hint: "返回对话并让小满调整"
        )

        XCTAssertEqual(descriptor.label, "调整任务")
        XCTAssertEqual(descriptor.value, "开会，明天下午 3 点")
        XCTAssertEqual(descriptor.hint, "返回对话并让小满调整")
    }

    private func contrastRatio(_ first: AIGTDRGBA, _ second: AIGTDRGBA) -> Double {
        let lighter = max(relativeLuminance(first), relativeLuminance(second))
        let darker = min(relativeLuminance(first), relativeLuminance(second))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ color: AIGTDRGBA) -> Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * channel(color.red)
            + 0.7152 * channel(color.green)
            + 0.0722 * channel(color.blue)
    }
}
