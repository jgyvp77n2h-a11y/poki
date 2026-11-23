import XCTest

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
}
