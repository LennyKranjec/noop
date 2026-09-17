import XCTest
@testable import Strand

/// Reading a Govee thermo-hygrometer off its Bluetooth advertisement, and the evening advice.
final class GoveeAdvertisementTests: XCTestCase {

    func testThePackedFormatOfTheH5075Family() {
        // 21.5 °C, 48.3 % → 215 * 1000 + 483 = 215483 = 0x0349BB, battery 87.
        let data = Data([0x88, 0xEC, 0x00, 0x03, 0x49, 0xBB, 87, 0x00])
        let p = GoveeAdvertisement.parse(name: "GVH5075_1A2B", manufacturerData: data)
        XCTAssertEqual(p?.temperatureC ?? 0, 21.5, accuracy: 0.001)
        XCTAssertEqual(p?.humidityPct ?? 0, 48.3, accuracy: 0.001)
        XCTAssertEqual(p?.battery, 87)
    }

    func testAFreezingReadingSetsTheTopBit() {
        // −2.3 °C, 60.0 % → 23 * 1000 + 600 = 23600 = 0x005C30, with 0x800000 set.
        let data = Data([0x88, 0xEC, 0x00, 0x80, 0x5C, 0x30, 50, 0x00])
        let p = GoveeAdvertisement.parse(name: "GVH5177_0001", manufacturerData: data)
        XCTAssertEqual(p?.temperatureC ?? 0, -2.3, accuracy: 0.001)
        XCTAssertEqual(p?.humidityPct ?? 0, 60.0, accuracy: 0.001)
    }

    func testTheLittleEndianFormatOfTheH5074() {
        // 19.25 °C = 1925 = 0x0785, 55.10 % = 5510 = 0x1586, battery 100.
        let data = Data([0x88, 0xEC, 0x00, 0x85, 0x07, 0x86, 0x15, 100, 0x02])
        let p = GoveeAdvertisement.parse(name: "Govee_H5074_ABCD", manufacturerData: data)
        XCTAssertEqual(p?.temperatureC ?? 0, 19.25, accuracy: 0.001)
        XCTAssertEqual(p?.humidityPct ?? 0, 55.10, accuracy: 0.001)
        XCTAssertEqual(p?.battery, 100)
    }

    func testAnythingElseIsNotRead() {
        // Wrong company, unknown model, too short.
        XCTAssertNil(GoveeAdvertisement.parse(name: "GVH5075", manufacturerData: Data([0x4C, 0x00, 0, 3, 0x49, 0xBB, 87, 0])))
        XCTAssertNil(GoveeAdvertisement.parse(name: "Some Speaker", manufacturerData: Data([0x88, 0xEC, 0, 3, 0x49, 0xBB, 87, 0])))
        XCTAssertNil(GoveeAdvertisement.parse(name: "GVH5075", manufacturerData: Data([0x88, 0xEC, 0])))
    }

    func testTheAdviceNamesWhatIsOffAndNothingWhenTheRoomIsFine() {
        func reading(_ t: Double, _ h: Double) -> ClimateReading {
            ClimateReading(temperatureC: t, humidityPct: h, battery: nil, deviceName: "x", source: "test", at: Date())
        }
        XCTAssertTrue(ClimateAdvice.issues(reading(18, 50)).isEmpty)
        XCTAssertEqual(ClimateAdvice.issues(reading(22.4, 50)).count, 1)
        XCTAssertEqual(ClimateAdvice.issues(reading(22.4, 30)).count, 2)
        XCTAssertEqual(ClimateAdvice.issues(reading(14, 70)).count, 2)
    }
}
