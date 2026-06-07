import XCTest
@testable import HeadroomKit

final class CursorUsageDecodingTests: XCTestCase {
    func testDecodesCurrentPeriodUsageFixture() throws {
        let data = try fixtureData(named: "cursor-period-usage.json")
        let response = try JSONDecoder().decode(CursorUsageClient.PeriodUsageResponse.self, from: data)

        XCTAssertEqual(response.planUsage?.autoPercentUsed, 12.5)
        XCTAssertEqual(response.planUsage?.apiPercentUsed, 46.444)
        XCTAssertEqual(response.billingCycleEnd, "1771077734000")
    }

    func testDecodesLegacyUsageFixture() throws {
        let data = try fixtureData(named: "cursor-legacy-usage.json")
        let response = try JSONDecoder().decode(CursorUsageClient.LegacyUsageResponse.self, from: data)

        XCTAssertEqual(response.startOfMonth, "2026-03-01T00:00:00.000Z")
        XCTAssertEqual(response.modelBuckets["gpt-4"]?.numRequests, 150)
        XCTAssertEqual(response.modelBuckets["gpt-4"]?.maxRequestUsage, 500)
    }

    private func fixtureData(named name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
}
