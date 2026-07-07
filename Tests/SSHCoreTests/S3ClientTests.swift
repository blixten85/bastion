import XCTest
@testable import SSHCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fångar upp begäran istället för att göra ett riktigt nätverksanrop —
/// för att inspektera VILKA headers `S3Client` faktiskt skickar (CodeRabbit-
/// fynd, PR #90: port i signerad Host, `contentType`-headern), utan att
/// bero på ett riktigt nätverk för just den detaljen.
private final class RecordingURLProtocol: URLProtocol {
    static var lastRequest: URLRequest?
    static var responseBody = Data("<?xml version=\"1.0\"?><ListAllMyBucketsResult><Buckets></Buckets></ListAllMyBucketsResult>".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class S3ClientTests: XCTestCase {
    /// Fixerad, icke tidsberoende SigV4-vektor — härledd ur en oberoende
    /// Python-referensimplementation (samma algoritm) som fick ett genuint
    /// 200 OK mot Hostups riktiga S3-kompatibla tjänst med riktiga nycklar
    /// (se S3Client.swifts huvudkommentar). Låser signeringskedjan mot
    /// regression utan att vara beroende av "nu".
    func testSigV4MatchesVerifiedReferenceVector() {
        let credentials = S3Credentials(
            accessKeyID: "AKIDEXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
        let signed = AWSSigV4.sign(
            method: "GET",
            host: "examplebucket.s3.hostup.se",
            path: "/test.txt",
            queryString: "",
            payload: Data(),
            region: "us-east-1",
            credentials: credentials,
            amzDate: "20260101T000000Z")

        XCTAssertEqual(signed.contentSHA256, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(
            signed.authorizationHeader,
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20260101/us-east-1/s3/aws4_request, "
                + "SignedHeaders=host;x-amz-content-sha256;x-amz-date, "
                + "Signature=2cf4e62d28a10475635f645779da044490aebcce8d9475e44a59523e179c5785")
    }

    func testSigV4DiffersWithDifferentPayload() {
        let credentials = S3Credentials(accessKeyID: "AKID", secretAccessKey: "secret")
        let empty = AWSSigV4.sign(
            method: "PUT", host: "h", path: "/x", queryString: "", payload: Data(),
            region: "us-east-1", credentials: credentials, amzDate: "20260101T000000Z")
        let nonEmpty = AWSSigV4.sign(
            method: "PUT", host: "h", path: "/x", queryString: "", payload: Data("hej".utf8),
            region: "us-east-1", credentials: credentials, amzDate: "20260101T000000Z")
        XCTAssertNotEqual(empty.authorizationHeader, nonEmpty.authorizationHeader)
        XCTAssertNotEqual(empty.contentSHA256, nonEmpty.contentSHA256)
    }

    // MARK: - XML-parsning (riktiga svarsformat, fångade från Hostups tjänst)

    func testParsesRealListBucketsResponse() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><ListAllMyBucketsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Owner><ID>client_9455$main</ID><DisplayName>Client 9455</DisplayName></Owner><Buckets><Bucket><Name>bastion-test</Name><CreationDate>2026-07-07T09:30:00.000Z</CreationDate></Bucket></Buckets></ListAllMyBucketsResult>
        """
        let buckets = S3XMLParser.parseBuckets(Data(xml.utf8))
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets.first?.name, "bastion-test")
        XCTAssertNotNil(buckets.first?.creationDate)
    }

    func testParsesListObjectsResponse() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>bastion-test</Name><Contents><Key>hello.txt</Key><LastModified>2026-07-07T09:31:00.000Z</LastModified><Size>5</Size></Contents></ListBucketResult>
        """
        let objects = S3XMLParser.parseObjects(Data(xml.utf8))
        XCTAssertEqual(objects.count, 1)
        XCTAssertEqual(objects.first?.key, "hello.txt")
        XCTAssertEqual(objects.first?.size, 5)
    }

    func testParsesErrorResponse() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><Error><Code>NoSuchBucket</Code><Message>The specified bucket does not exist.</Message></Error>
        """
        let err = S3XMLParser.parseError(Data(xml.utf8))
        XCTAssertEqual(err.code, "NoSuchBucket")
        XCTAssertEqual(err.message, "The specified bucket does not exist.")
    }

    // MARK: - Live-verifiering mot en RIKTIG S3-kompatibel tjänst

    /// Körs bara om riktiga Hostup-nycklar finns i miljön (satta via
    /// `.env`, aldrig hårdkodade eller committade) — hoppar tyst över annars
    /// (t.ex. i CI, som inte har dessa hemligheter). Bevisar hela kedjan
    /// end-to-end: skapa bucket, ladda upp, lista, ladda ner, verifiera
    /// innehåll, städa upp — mot Hostups genuina `s3.hostup.se`, inte en
    /// mockad server.
    func testLiveRoundTripAgainstRealHostupS3() async throws {
        guard let accessKey = ProcessInfo.processInfo.environment["HOSTUP_S3_ACCESS_KEY"],
              let secretKey = ProcessInfo.processInfo.environment["HOSTUP_S3_SECRET_KEY"],
              let endpointString = ProcessInfo.processInfo.environment["HOSTUP_S3_ENDPOINT"],
              let endpoint = URL(string: endpointString)
        else {
            throw XCTSkip("HOSTUP_S3_* saknas i miljön — hoppar över live-testet (t.ex. i CI).")
        }

        let client = S3Client(
            endpoint: endpoint, region: "us-east-1",
            credentials: S3Credentials(accessKeyID: accessKey, secretAccessKey: secretKey))

        let bucket = "bastion-livetest-\(UUID().uuidString.lowercased().prefix(12))"
        let key = "hello.txt"
        let content = Data("Hej från Bastions S3-klienttest, \(Date()).".utf8)

        try await client.createBucket(bucket)
        addTeardownBlock {
            try? await client.deleteObject(bucket: bucket, key: key)
            try? await client.deleteBucket(bucket)
        }

        try await client.putObject(bucket: bucket, key: key, data: content)

        let listed = try await client.listObjects(bucket: bucket)
        XCTAssertEqual(listed.map(\.key), [key])
        XCTAssertEqual(listed.first?.size, Int64(content.count))

        let downloaded = try await client.getObject(bucket: bucket, key: key)
        XCTAssertEqual(downloaded, content)

        let buckets = try await client.listBuckets()
        XCTAssertTrue(buckets.contains { $0.name == bucket })
    }

    // MARK: - Regressionstester för CodeRabbit-fynd (PR #90)

    private func recordingClient(endpoint: URL) -> S3Client {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingURLProtocol.self]
        return S3Client(
            endpoint: endpoint, region: "us-east-1",
            credentials: S3Credentials(accessKeyID: "AKID", secretAccessKey: "secret"),
            session: URLSession(configuration: config))
    }

    func testHostIncludesNonDefaultPort() async {
        let client = recordingClient(endpoint: URL(string: "http://localhost:9000")!)
        let host = await client.host
        XCTAssertEqual(host, "localhost:9000")
    }

    func testHostOmitsDefaultHTTPSPort() async {
        let client = recordingClient(endpoint: URL(string: "https://s3.hostup.se:443")!)
        let host = await client.host
        XCTAssertEqual(host, "s3.hostup.se")
    }

    func testHostOmitsWhenNoPortSpecified() async {
        let client = recordingClient(endpoint: URL(string: "https://s3.hostup.se")!)
        let host = await client.host
        XCTAssertEqual(host, "s3.hostup.se")
    }

    func testPutObjectSetsContentTypeHeader() async throws {
        let client = recordingClient(endpoint: URL(string: "https://example.com")!)
        try await client.putObject(bucket: "b", key: "k", data: Data("hej".utf8), contentType: "text/plain")

        let sent = try XCTUnwrap(RecordingURLProtocol.lastRequest)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "text/plain")
    }

    func testPutObjectOmitsContentTypeHeaderWhenNil() async throws {
        let client = recordingClient(endpoint: URL(string: "https://example.com")!)
        try await client.putObject(bucket: "b", key: "k", data: Data("hej".utf8))

        let sent = try XCTUnwrap(RecordingURLProtocol.lastRequest)
        XCTAssertNil(sent.value(forHTTPHeaderField: "Content-Type"))
    }
}
