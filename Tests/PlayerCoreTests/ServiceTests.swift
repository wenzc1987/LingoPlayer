import Testing
import Foundation
@testable import PlayerCore

final class ServiceTests {
    @Test func testReleaseNamesExtractMovieAndEpisodeMetadata() {
        let movie = ReleaseQuery(filename: "The.Matrix.1999.1080p.BluRay.x264.mkv")
        #expect(movie.title == "The Matrix"); #expect(movie.year == 1999)
        let series = ReleaseQuery(filename: "Friends.S02E03.1080p.WEB-DL.mkv")
        #expect(series.title == "Friends"); #expect(series.season == 2); #expect(series.episode == 3)
        let alternate = ReleaseQuery(filename: "Show.Name.1x12.720p.mp4")
        #expect(alternate.title == "Show Name"); #expect(alternate.episode == 12)
    }
    @Test func testOpenSubtitlesHashReadsBothEndsInLittleEndian() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var data = Data(repeating: 0, count: 131_072)
        data[0] = 1; data[65_536] = 2; data[131_071] = 1
        try data.write(to: url)
        #expect(try OpenSubtitlesHash.compute(url: url) == "0100000000020003")
        try Data(repeating: 0, count: 30).write(to: url)
        #expect(try OpenSubtitlesHash.compute(url: url) == nil)
    }
    @Test func testCandidatesPrioritizeFileMatchOverPopularity() throws {
        let json = """
        {"data":[{"attributes":{"language":"en","download_count":900,"moviehash_match":false,"files":[{"file_id":1,"file_name":"popular.srt"}]}},{"attributes":{"language":"en","download_count":2,"moviehash_match":true,"hearing_impaired":true,"files":[{"file_id":2,"file_name":"exact.srt"}]}}]}
        """
        let rows = try OpenSubtitlesClient.parseCandidates(Data(json.utf8))
        #expect(rows.map(\.id) == [2, 1]); #expect(rows[0].hearingImpaired)
    }
    @Test func testUnconfiguredServiceDoesNotAttemptNetwork() async {
        do { _ = try await OpenSubtitlesClient(apiKey: "").search(query: ReleaseQuery(filename: "film.mp4"), hash: nil, language: .english); Issue.record("Expected configuration error") }
        catch { #expect(error.localizedDescription.contains("API Key")) }
    }
    private func mockClient(_ scenario: String) -> OpenSubtitlesClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubtitleMockProtocol.self]
        return OpenSubtitlesClient(apiKey: scenario, token: "test-token", session: URLSession(configuration: configuration))
    }
    @Test func testUnavailableAndUnauthenticatedServiceReturnClearErrors() async {
        for status in [401, 503] {
            do {
                _ = try await mockClient(String(status)).search(query: ReleaseQuery(filename: "Film.2000.mp4"), hash: nil, language: .english)
                Issue.record("Expected service error")
            } catch { #expect(error.localizedDescription.contains(String(status))) }
        }
    }
    @Test func testOfflineServiceReturnsWithoutBlockingLocalWork() async {
        do {
            _ = try await mockClient("offline").search(query: ReleaseQuery(filename: "Film.mp4"), hash: nil, language: .english)
            Issue.record("Expected offline error")
        } catch { #expect((error as NSError).code == URLError.notConnectedToInternet.rawValue) }
    }
    @Test func testDownloadDoesNotForwardCredentialsToSignedURL() async throws {
        let data = try await mockClient("download").download(fileID: 123)
        #expect(String(decoding: data, as: UTF8.self).contains("Hello"))
    }
    @Test func testSubprocessHandlesLargeOutputWithoutDeadlock() async throws {
        let result = try await ProcessRunner.run(executable: "/usr/bin/python3", arguments: ["-c", "import sys; print('x'*200000); sys.stderr.write('e'*200000)"], timeout: 15)
        #expect(result.output.count == 200001)
    }
    @Test func testSubprocessCancellation() async throws {
        let task = Task { try await ProcessRunner.run(executable: "/bin/sleep", arguments: ["30"], timeout: 40) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancellation expected") }
        catch is CancellationError {}
    }
    @Test func testSubprocessFailureIncludesDiagnostic() async {
        do { _ = try await ProcessRunner.run(executable: "/usr/bin/python3", arguments: ["-c", "import sys; sys.stderr.write('fixture failure'); sys.exit(3)"]); Issue.record("Failure expected") }
        catch { #expect(error.localizedDescription.contains("fixture failure")) }
    }
}

private final class SubtitleMockProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let scenario = request.value(forHTTPHeaderField: "Api-Key") ?? ""
        if scenario == "offline" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        var status = 200
        let body: String
        if url.host == "signed.example.test" {
            let clean = request.value(forHTTPHeaderField: "Api-Key") == nil && request.value(forHTTPHeaderField: "Authorization") == nil
            status = clean ? 200 : 403
            body = "1\n00:00:00,000 --> 00:00:01,000\nHello\n"
        } else if scenario == "download" {
            body = "{\"link\":\"https://signed.example.test/subtitle.srt\"}"
        } else {
            status = Int(scenario) ?? 500
            body = "{\"message\":\"fixture service failure\"}"
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
