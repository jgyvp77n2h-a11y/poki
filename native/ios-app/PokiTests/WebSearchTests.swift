import XCTest
@testable import Poki

final class WebSearchTests: XCTestCase {
    func testConfigRoundTrip() throws {
        var config = WebSearchConfig()
        config.url = "https://example.test/search"
        config.method = "POST"
        config.queryParam = "query"
        config.keyHeader = "Authorization"
        config.keyScheme = "Bearer"
        config.resultPath = "data.results"
        config.titleKeys = ["title"]
        config.urlKeys = ["link"]
        config.snippetKeys = ["snippet"]
        config.topK = 4
        config.timeout = 12
        config.extraHeaders = ["Accept-Language": "zh-CN"]
        config.extraBody = ["scope": "web"]

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(WebSearchConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testDefaultConfig() {
        let config = WebSearchConfig()
        XCTAssertTrue(config.url.isEmpty)
        XCTAssertEqual(config.method, "GET")
        XCTAssertEqual(config.queryParam, "q")
        XCTAssertEqual(config.topK, 5)
        XCTAssertEqual(config.timeout, 20)
    }

    func testPresetRoundTripKeepsIdentity() throws {
        var config = WebSearchConfig()
        config.url = "https://example.test/search"
        let preset = WebSearchPreset(id: "preset-a", name: "示例", config: config)
        let data = try JSONEncoder().encode([preset])
        let decoded = try JSONDecoder().decode([WebSearchPreset].self, from: data)
        XCTAssertEqual(decoded, [preset])
        XCTAssertEqual(decoded.first?.name, "示例")
        XCTAssertTrue(decoded.first?.isConfigured == true)
    }

    func testPresetFallsBackToHostWhenUnnamed() {
        var config = WebSearchConfig()
        config.url = "https://search.example.test/v1/search"
        let preset = WebSearchPreset(name: "  ", config: config)
        XCTAssertEqual(preset.title, "search.example.test")
        XCTAssertEqual(preset.detail, "search.example.test/v1/search")
    }

    func testPresetWithoutAddressIsNotConfigured() {
        let preset = WebSearchPreset(name: "空")
        XCTAssertFalse(preset.isConfigured)
        XCTAssertEqual(preset.detail, "还没填地址")
    }

    func testUnusedNameAvoidsTakenNames() {
        let first = WebSearchPreset(name: "预设 1")
        let second = WebSearchPreset(name: "预设 2")
        XCTAssertEqual(WebSearchPresets.unusedName(in: [first, second]), "预设 3")
        XCTAssertEqual(WebSearchPresets.unusedName(in: []), "预设 1")
    }
}
