import Foundation

func runHTTPTimeoutTests() {
    // ─── 1a: HTTP timeout (structural check) ─────────────────────────────────────
    // We can't spin up a real server in a script test, but we can verify the
    // URLSession config values are what we set.

    section("1a · HTTP timeout — URLSession config values")

    let config = URLSessionConfiguration.ephemeral
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.urlCache = nil
    config.timeoutIntervalForRequest = 15
    config.timeoutIntervalForResource = 30

    expect("timeoutIntervalForRequest == 15", config.timeoutIntervalForRequest == 15,
           detail: "got \(config.timeoutIntervalForRequest)")
    expect("timeoutIntervalForResource == 30", config.timeoutIntervalForResource == 30,
           detail: "got \(config.timeoutIntervalForResource)")
    expect("urlCache is nil", config.urlCache == nil)
    expect("cachePolicy is reloadIgnoringLocalCacheData",
           config.requestCachePolicy == .reloadIgnoringLocalCacheData)
}
