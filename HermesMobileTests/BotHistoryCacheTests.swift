import XCTest
@testable import HermesMobile

final class BotHistoryCacheTests: XCTestCase {
    private let server = URL(string: "https://one.example")!
    private let otherServer = URL(string: "https://two.example")!
    private let connection = UUID()

    private func message(_ id: String, _ text: String, role: String = "assistant") -> ChatMessage {
        ChatMessage(role: role, content: text, timestamp: nil, messageId: id)
    }

    func testSearchReturnsIndividualIncomingAndOutgoingMessagesOnlyWithinCapturedIdentity() async throws {
        let cache = BotHistoryCache()
        let scope = BotHistoryCache.Scope(server: server, connectionID: connection)
        let otherScope = BotHistoryCache.Scope(server: otherServer, connectionID: connection)
        let replacement = BotHistoryCache.Scope(server: server, connectionID: UUID())
        for owner in [scope, otherScope, replacement] {
            try await cache.replace(scope: owner, profileID: "inbox", root: "root", tip: "tip", messages: [
                message("one", "Newport this Friday", role: "user"),
                message("two", "Yes, Newport is available"),
                message("tool", "Newport tool result", role: "tool"),
                message("unknown", "Newport", role: "future-role")
            ])
        }
        try await cache.replace(scope: scope, profileID: "another", root: "root", tip: "tip", messages: [message("one", "Newport")])
        let hits = try await cache.search("NEWPORT", scope: scope, profileIDs: ["inbox"])
        XCTAssertEqual(hits.map(\.message.id), ["two", "one"])
        XCTAssertEqual(hits.map(\.message.role), ["assistant", "user"])
        XCTAssertTrue(hits.allSatisfy { $0.snapshot.scope == scope && $0.snapshot.profileID == "inbox" })
        let empty = try await cache.search("  ", scope: scope, profileIDs: ["inbox"])
        XCTAssertTrue(empty.isEmpty)
    }

    func testReplacementDropsUndoneHistoryAndRetainsFrozenResultForReadOnlyNavigation() async throws {
        let cache = BotHistoryCache()
        let scope = BotHistoryCache.Scope(server: server, connectionID: connection)
        try await cache.replace(scope: scope, profileID: "inbox", root: "root", tip: "tip", messages: [message("root/0", "Newport")])
        let hits = try await cache.search("Newport", scope: scope, profileIDs: ["inbox"])
        let selected = try XCTUnwrap(hits.first)
        try await cache.replace(scope: scope, profileID: "inbox", root: "root", tip: "compressed", messages: [message("root/0", "Manhattan")])
        let afterCompression = try await cache.search("Newport", scope: scope, profileIDs: ["inbox"])
        XCTAssertTrue(afterCompression.isEmpty)
        XCTAssertEqual(selected.snapshot.tip, "tip")
        XCTAssertEqual(selected.snapshot.messages.first?.text, "Newport")
        try await cache.replace(scope: scope, profileID: "inbox", root: "replacement", tip: "replacement", messages: [])
        let afterReset = try await cache.search("Manhattan", scope: scope, profileIDs: ["inbox"])
        XCTAssertTrue(afterReset.isEmpty)
    }

    func testCacheSurvivesRelaunchAndHasNoServerAddressInItsFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = BotHistoryCache.Scope(server: server, connectionID: connection)
        let cache = BotHistoryCache(directory: directory)
        try await cache.replace(scope: scope, profileID: "inbox", root: "root", tip: "tip", messages: [message("one", "Newport")])
        let restored = BotHistoryCache(directory: directory)
        let hits = try await restored.search("Newport", scope: scope, profileIDs: ["inbox"])
        XCTAssertEqual(hits.map(\.message.id), ["one"])
        let offlineHits = try await restored.search("Newport", scope: scope, profileIDs: nil)
        XCTAssertEqual(offlineHits.count, 1, "A temporarily unavailable roster must not hide the on-device cache")
        let deletedBotHits = try await restored.search("Newport", scope: scope, profileIDs: [])
        XCTAssertTrue(deletedBotHits.isEmpty, "An authoritative live roster excludes removed bots")
        let disk = try String(contentsOf: directory.appendingPathComponent("history.json"), encoding: .utf8)
        XCTAssertFalse(disk.contains(server.absoluteString))
        XCTAssertFalse(disk.contains("runtime"))
    }

    func testExpiredHistoryIsPrunedFromDiskOnLoadAndLaterSearch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = BotHistoryCache.Scope(server: server, connectionID: connection)
        let now = Date()
        let cache = BotHistoryCache(directory: directory)
        try await cache.replace(scope: scope, profileID: "old", root: "root", tip: "tip",
                                messages: [message("old", "Expired Newport")],
                                receivedAt: now.addingTimeInterval(-BotHistoryCache.lifetime - 1))
        let restored = BotHistoryCache(directory: directory)
        let expired = try await restored.search("Newport", scope: scope, profileIDs: nil)
        XCTAssertTrue(expired.isEmpty)
        let file = directory.appendingPathComponent("history.json")
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("Expired Newport"))
        try await restored.replace(scope: scope, profileID: "new", root: "root", tip: "tip",
                                   messages: [message("new", "Fresh Newport")], receivedAt: now)
        let later = try await restored.search("Newport", scope: scope, profileIDs: nil,
                                             now: now.addingTimeInterval(BotHistoryCache.lifetime + 1))
        XCTAssertTrue(later.isEmpty)
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("Fresh Newport"))
    }

    func testClearIsServerScopedAndRejectsEarlierQueuedWrites() async throws {
        let cache = BotHistoryCache()
        let now = Date()
        let scope = BotHistoryCache.Scope(server: server, connectionID: connection)
        let other = BotHistoryCache.Scope(server: otherServer, connectionID: connection)
        for owner in [scope, other] {
            try await cache.replace(scope: owner, profileID: "inbox", root: "root", tip: "tip", messages: [message("one", "Newport")], receivedAt: now)
        }
        try await cache.remove(server: server, now: now.addingTimeInterval(1))
        try await cache.replace(scope: scope, profileID: "inbox", root: "root", tip: "tip", messages: [message("old", "Newport")], receivedAt: now)
        let cleared = try await cache.search("Newport", scope: scope, profileIDs: ["inbox"])
        let retained = try await cache.search("Newport", scope: other, profileIDs: ["inbox"])
        XCTAssertTrue(cleared.isEmpty)
        XCTAssertEqual(retained.count, 1)
        try await cache.replace(scope: scope, profileID: "inbox", root: "root", tip: "tip", messages: [message("new", "Newport")], receivedAt: now.addingTimeInterval(2))
        let fresh = try await cache.search("Newport", scope: scope, profileIDs: ["inbox"])
        XCTAssertEqual(fresh.map(\.message.id), ["new"])
    }

    func testRemovingConnectionRevokesFutureWritesAndPreservesOtherConnection() async throws {
        let cache = BotHistoryCache()
        let scope = BotHistoryCache.Scope(server: server, connectionID: connection)
        let other = BotHistoryCache.Scope(server: server, connectionID: UUID())
        try await cache.remove(server: server, connectionID: connection)
        for owner in [scope, other] {
            try await cache.replace(scope: owner, profileID: "inbox", root: "root", tip: "tip", messages: [message("one", "Newport")])
        }
        let removed = try await cache.search("Newport", scope: scope, profileIDs: ["inbox"])
        let retained = try await cache.search("Newport", scope: other, profileIDs: ["inbox"])
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(retained.count, 1)
    }

    func testLateSnapshotCannotOverwriteANewerSnapshotAndServerRemovalPurgesAllConnections() async throws {
        let cache = BotHistoryCache()
        let scope = BotHistoryCache.Scope(server: server, connectionID: connection)
        let oldConnection = BotHistoryCache.Scope(server: server, connectionID: UUID())
        let now = Date()
        try await cache.replace(scope: scope, profileID: "inbox", root: "root", tip: "new", messages: [message("new", "Newport")], receivedAt: now)
        try await cache.replace(scope: scope, profileID: "inbox", root: "root", tip: "old", messages: [message("old", "Newport")], receivedAt: now.addingTimeInterval(-1))
        let current = try await cache.search("Newport", scope: scope, profileIDs: ["inbox"])
        XCTAssertEqual(current.map(\.message.id), ["new"])
        try await cache.replace(scope: oldConnection, profileID: "inbox", root: "root", tip: "old", messages: [message("old", "Newport")])
        try await cache.removeServer(server, activeConnectionID: connection)
        for owner in [scope, oldConnection] {
            try await cache.replace(scope: owner, profileID: "inbox", root: "root", tip: "old", messages: [message("late", "Newport")])
            let remaining = try await cache.search("Newport", scope: owner, profileIDs: ["inbox"])
            XCTAssertTrue(remaining.isEmpty)
        }
    }

    func testCacheBoundsResultsAndExpiryAndHandlesUnicode() async throws {
        let cache = BotHistoryCache()
        let scope = BotHistoryCache.Scope(server: server, connectionID: connection)
        let now = Date()
        var rows = (0..<600).map { message(String($0), "Café près de Newport 🏡") }
        rows.append(message("large", String(repeating: "Newport", count: 5000)))
        try await cache.replace(scope: scope, profileID: "inbox", root: "root", tip: "tip", messages: rows, receivedAt: now)
        let hits = try await cache.search("CAFÉ", scope: scope, profileIDs: ["inbox"], now: now)
        XCTAssertEqual(hits.count, BotHistoryCache.maximumHits)
        XCTAssertLessThanOrEqual(hits[0].snapshot.messages.count, BotHistoryCache.maximumMessages)
        XCTAssertFalse(hits.contains { $0.message.id == "large" })
        let expired = try await cache.search("Newport", scope: scope, profileIDs: ["inbox"], now: now.addingTimeInterval(BotHistoryCache.lifetime + 1))
        XCTAssertTrue(expired.isEmpty)
    }
}
