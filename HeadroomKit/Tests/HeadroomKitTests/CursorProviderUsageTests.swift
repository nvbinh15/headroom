import XCTest
import SQLite3
@testable import HeadroomKit

final class CursorProviderUsageTests: XCTestCase {
    func testMapsAutoAndAPIUsageFromPeriodResponse() throws {
        let data = try fixtureData(named: "cursor-period-usage.json")
        let response = try JSONDecoder().decode(CursorUsageClient.PeriodUsageResponse.self, from: data)

        let usage = try XCTUnwrap(CursorUsageMapper.providerUsage(
            from: response,
            planName: "Ultra",
            membershipType: "ultra"
        ))

        XCTAssertEqual(usage.fiveHourLabel, "Auto")
        XCTAssertEqual(usage.weeklyLabel, "API")
        XCTAssertEqual(usage.fiveHour?.fraction ?? 0, 0.125, accuracy: 0.0001)
        XCTAssertEqual(usage.weekly?.fraction ?? 0, 0.46444, accuracy: 0.0001)
        XCTAssertNotNil(usage.fiveHour?.resetsAt)
        XCTAssertEqual(usage.planLabel, "Ultra")
    }

    func testMapsLegacyRequestUsage() throws {
        let data = try fixtureData(named: "cursor-legacy-usage.json")
        let response = try JSONDecoder().decode(CursorUsageClient.LegacyUsageResponse.self, from: data)

        let usage = try XCTUnwrap(CursorUsageMapper.providerUsage(
            from: response,
            membershipType: "enterprise"
        ))

        XCTAssertEqual(usage.fiveHourLabel, "Requests")
        XCTAssertNil(usage.weekly)
        XCTAssertEqual(usage.fiveHour?.fraction ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertEqual(usage.planLabel, "Enterprise")
    }

    func testReadsCredentialsFromSQLiteFixture() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("state.vscdb")
        try createSQLiteFixture(
            at: dbURL,
            rows: [
                ("cursorAuth/accessToken", "test-access-token"),
                ("cursorAuth/refreshToken", "test-refresh-token"),
                ("cursorAuth/stripeMembershipType", "pro")
            ]
        )

        let credentials = try XCTUnwrap(CursorCredentialsLoader.loadFromSQLite(at: dbURL))
        XCTAssertEqual(credentials.accessToken, "test-access-token")
        XCTAssertEqual(credentials.refreshToken, "test-refresh-token")
        XCTAssertEqual(credentials.membershipType, "pro")
    }

    private func fixtureData(named name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func createSQLiteFixture(at url: URL, rows: [(String, String)]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "CursorProviderUsageTests", code: 1)
        }
        defer { sqlite3_close(db) }

        let createSQL = "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);"
        guard sqlite3_exec(db, createSQL, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "CursorProviderUsageTests", code: 2)
        }

        for (key, value) in rows {
            var statement: OpaquePointer?
            let insertSQL = "INSERT INTO ItemTable (key, value) VALUES (?, ?);"
            guard sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK,
                  let statement
            else {
                throw NSError(domain: "CursorProviderUsageTests", code: 3)
            }
            sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(statement, 2, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                sqlite3_finalize(statement)
                throw NSError(domain: "CursorProviderUsageTests", code: 4)
            }
            sqlite3_finalize(statement)
        }
    }
}
