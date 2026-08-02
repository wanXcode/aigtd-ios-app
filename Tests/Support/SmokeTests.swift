import XCTest
@testable import AIGTDReminders

final class SmokeTests: XCTestCase {
    func testApplicationModuleLoads() {
        XCTAssertTrue(true)
    }

    @MainActor
    func testXiaomanWelcomeIsConsumedOnlyOnce() throws {
        let suiteName = "SmokeTests.XiaomanWelcome.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = XiaomanWelcomeStore(defaults: defaults)

        XCTAssertTrue(store.shouldPresentWelcome)
        XCTAssertEqual(store.consumeWelcomeMessage(), XiaomanWelcomeStore.welcomeMessage)
        XCTAssertFalse(store.shouldPresentWelcome)
        XCTAssertNil(store.consumeWelcomeMessage())
    }

    @MainActor
    func testXiaomanWelcomePersistsAcrossStoreInstances() throws {
        let suiteName = "SmokeTests.XiaomanWelcome.Persistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstStore = XiaomanWelcomeStore(defaults: defaults)
        XCTAssertNotNil(firstStore.consumeWelcomeMessage())

        let restoredStore = XiaomanWelcomeStore(defaults: defaults)
        XCTAssertFalse(restoredStore.shouldPresentWelcome)
        XCTAssertNil(restoredStore.consumeWelcomeMessage())
    }
}
