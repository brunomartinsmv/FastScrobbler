import Foundation
import CryptoKit

func runAPITests() {
    // ─── API signature generation ─────────────────────────────────────────────────
    // Replicates apiSignature(params:) from LastFMClient.swift.
    // Uses CryptoKit MD5: sorted filtered params concatenated + secret, then MD5 hex.


    section("API · Signature generation (MD5)")

    func apiSignature(params: [String: String], secret: String) -> String {
        let filtered = params.filter { $0.key != "format" }
        let base = filtered
            .sorted(by: { $0.key < $1.key })
            .map { $0.key + $0.value }
            .joined() + secret
        let digest = Insecure.MD5.hash(data: Data(base.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    let sigParams: [String: String] = ["method": "auth.getToken", "api_key": "testkey", "format": "json"]
    let sig = apiSignature(params: sigParams, secret: "testsecret")

    // "api_key" + "testkey" + "method" + "auth.getToken" + "testsecret" (format excluded, sorted)
    let expectedSigBase = "api_keytestkeymethodauth.getTokentestsecret"
    let expectedDigest = Insecure.MD5.hash(data: Data(expectedSigBase.utf8))
    let expectedSig = expectedDigest.map { String(format: "%02x", $0) }.joined()

    expect("signature is 32 hex chars",              sig.count == 32, detail: "got \(sig.count) chars")
    expect("signature matches expected MD5",         sig == expectedSig, detail: "got '\(sig)'")
    expect("format key excluded from signature",     sig == apiSignature(params: sigParams.filter { $0.key != "format" }, secret: "testsecret"))
    expect("different secret = different signature", sig != apiSignature(params: sigParams, secret: "othersecret"))

    // Parameter order doesn't affect result (always sorted internally)
    let sigAlt = apiSignature(params: ["api_key": "testkey", "format": "json", "method": "auth.getToken"], secret: "testsecret")
    expect("param dict order doesn't affect sig",    sig == sigAlt)

    // ─── URL form encoding ────────────────────────────────────────────────────────
    // Replicates urlEncode(_:) from LastFMClient.swift.
    // Note: space is percent-encoded to %20 (replace " "→"+" runs after encoding, so never fires).

    section("API · URL form encoding")

    func urlEncode(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
        return encoded.replacingOccurrences(of: " ", with: "+")
    }

    expect("space encodes to %20 (not +, replace fires post-encoding)", urlEncode("hello world") == "hello%20world",
           detail: "got '\(urlEncode("hello world"))'")
    expect("'&' encodes to %26",    urlEncode("a&b") == "a%26b",   detail: "got '\(urlEncode("a&b"))'")
    expect("'=' encodes to %3D",    urlEncode("a=b") == "a%3Db",   detail: "got '\(urlEncode("a=b"))'")
    expect("safe chars unchanged",  urlEncode("abc-._~") == "abc-._~", detail: "got '\(urlEncode("abc-._~"))'")
    expect("empty string unchanged",urlEncode("") == "")
    expect("'+' encodes to %2B",    urlEncode("a+b") == "a%2Bb", detail: "got '\(urlEncode("a+b"))'")

    // ─── API request metadata normalization ───────────────────────────────────────
    // Replicates applyOptionalTrackMetadata(from:to:) from LastFMClient.swift.

    section("API · Optional track metadata normalization")

    struct APITrack {
        let album: String?
        let albumArtist: String?
        let durationSeconds: Double?
    }

    func albumArtistForScrobbleMetadata(_ albumArtist: String?) -> String? {
        guard let trimmed = albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    func applyOptionalTrackMetadata(from track: APITrack, to params: inout [String: String]) {
        if let album = normalized(track.album) {
            params["album"] = album
        }
        if let albumArtist = albumArtistForScrobbleMetadata(track.albumArtist) {
            params["albumArtist"] = albumArtist
        }
        if let durationSeconds = track.durationSeconds, durationSeconds > 0 {
            params["duration"] = String(Int(durationSeconds.rounded()))
        }
    }

    var metaParams: [String: String] = [:]
    applyOptionalTrackMetadata(from: APITrack(album: "  Album Name  ", albumArtist: "  The Band  ", durationSeconds: 201.6), to: &metaParams)
    expect("album is trimmed before submission", metaParams["album"] == "Album Name", detail: "got '\(metaParams["album"] ?? "nil")'")
    expect("albumArtist is trimmed before submission", metaParams["albumArtist"] == "The Band", detail: "got '\(metaParams["albumArtist"] ?? "nil")'")
    expect("duration is rounded to nearest whole second", metaParams["duration"] == "202", detail: "got '\(metaParams["duration"] ?? "nil")'")

    var blankMetaParams: [String: String] = [:]
    applyOptionalTrackMetadata(from: APITrack(album: "   ", albumArtist: "\n", durationSeconds: 0), to: &blankMetaParams)
    expect("blank album is omitted", blankMetaParams["album"] == nil)
    expect("blank albumArtist is omitted", blankMetaParams["albumArtist"] == nil)
    expect("zero duration is omitted", blankMetaParams["duration"] == nil)

    var negativeDurationParams: [String: String] = [:]
    applyOptionalTrackMetadata(from: APITrack(album: nil, albumArtist: nil, durationSeconds: -1), to: &negativeDurationParams)
    expect("negative duration is omitted", negativeDurationParams["duration"] == nil)
}
