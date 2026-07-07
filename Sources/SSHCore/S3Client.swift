import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

/// S3-kompatibel objektlagringsklient (AWS Signature Version 4) — fungerar
/// mot riktig AWS S3 OCH mot S3-kompatibla leverantörer (Ceph RGW m.fl.),
/// eftersom SigV4 är en delad, väldokumenterad spec, inte en AWS-specifik
/// hemlighet. Motiveras av VISION.md "Native filhanterare-integration och
/// molnlagring som filkälla": AWS/S3-kompatibel lagring har inget
/// konsument-OAuth, användaren klistrar in sina egna nycklar.
///
/// Signeringen (`AWSSigV4`) är verifierad på TVÅ sätt, inte gissad:
/// 1. En oberoende Python-referensimplementation (samma algoritm, olika
///    språk) fick ett genuint 200 OK mot en RIKTIG S3-kompatibel tjänst
///    (Hostups `s3.hostup.se`, Ceph RGW) med riktiga nycklar.
/// 2. Testerna i `S3ClientTests.swift` låser en fixerad (icke tidsberoende)
///    canonical-request/string-to-sign/signature-kedja, härledd ur samma
///    verifierade algoritm — inte AWS:s publicerade doc-exempel (det
///    exemplet är för query-parameter-signering/presignerade URL:er, en
///    annan variant än header-baserad auth som den här klienten använder).
///
/// Path-style URL:er (`https://endpoint/bucket/key`), inte virtual-hosted
/// (`https://bucket.endpoint/key`) — Ceph RGW och de flesta S3-kompatibla
/// leverantörer stödjer path-style universellt, virtual-hosted kräver
/// wildcard-DNS som inte alla leverantörer sätter upp.
public struct S3Credentials: Sendable, Equatable {
    public let accessKeyID: String
    public let secretAccessKey: String

    public init(accessKeyID: String, secretAccessKey: String) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
    }
}

public struct S3Bucket: Sendable, Equatable {
    public let name: String
    public let creationDate: Date?
}

public struct S3Object: Sendable, Equatable {
    public let key: String
    public let size: Int64
    public let lastModified: Date?
}

public enum S3Error: Error, Sendable, Equatable {
    case transport(String)
    case httpError(status: Int, code: String, message: String)
    case malformedResponse
}

/// Ren, testbar SigV4-signering — inget nätverk, inget stateful. Se
/// `S3Client.swift`s huvudkommentar för hur den här är verifierad.
enum AWSSigV4 {
    struct SignedRequest {
        let authorizationHeader: String
        let amzDate: String
        let contentSHA256: String
    }

    /// En NY `DateFormatter` per anrop, medvetet — `swift-corelibs-foundation`
    /// (Linux) garanterar INTE att `DateFormatter.string(from:)` är
    /// trådsäkert för en delad instans (CodeRabbit-fynd, PR #90). Flera
    /// `S3Client`-instanser kan signera samtidigt, så en delad formatter
    /// hade kunnat race:a.
    static func isoDateFormatter() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date())
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(_ key: SymmetricKey, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key))
    }

    /// Bygger canonical request + string-to-sign + signatur och returnerar
    /// en klar `Authorization`-header. `path` måste redan vara URI-encodad
    /// (inte innehålla frågesträngen); `queryString` är den redan sorterade,
    /// encodade canonical query-strängen (tom sträng om ingen).
    static func sign(
        method: String,
        host: String,
        path: String,
        queryString: String,
        payload: Data,
        region: String,
        credentials: S3Credentials,
        amzDate: String
    ) -> SignedRequest {
        let datestamp = String(amzDate.prefix(8))
        let contentHash = sha256Hex(payload)

        let canonicalHeaders = "host:\(host)\nx-amz-content-sha256:\(contentHash)\nx-amz-date:\(amzDate)\n"
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"

        let canonicalRequest = [
            method,
            path,
            queryString,
            canonicalHeaders,
            signedHeaders,
            contentHash,
        ].joined(separator: "\n")

        let credentialScope = "\(datestamp)/\(region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let kDate = hmac(SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8)), datestamp)
        let kRegion = hmac(SymmetricKey(data: kDate), region)
        let kService = hmac(SymmetricKey(data: kRegion), "s3")
        let kSigning = hmac(SymmetricKey(data: kService), "aws4_request")
        let signature = hmac(SymmetricKey(data: kSigning), stringToSign).map { String(format: "%02x", $0) }.joined()

        let auth = "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(credentialScope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"

        return SignedRequest(authorizationHeader: auth, amzDate: amzDate, contentSHA256: contentHash)
    }
}

/// URI-encoding enligt SigV4-reglerna (RFC 3986, men `/` FÅR stå okodad i
/// sökvägen — till skillnad från AWS-signeringens hantering av enskilda
/// path-segment). `S3.encodePathSegment` kodar ETT segment (encodar `/`),
/// medan hela sökvägen sätts ihop med `/` mellan segmenten.
private func encodePathSegment(_ s: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}

private func encodePath(_ segments: [String]) -> String {
    "/" + segments.map(encodePathSegment).joined(separator: "/")
}

public actor S3Client {
    private let endpoint: URL
    private let region: String
    private let credentials: S3Credentials
    private let session: URLSession

    public init(endpoint: URL, region: String, credentials: S3Credentials, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.region = region
        self.credentials = credentials
        self.session = session
    }

    /// `Host`-värdet som faktiskt måste signeras — `URLSession` skickar
    /// `Host: värd:port` för icke-standardportar (t.ex. en lokal MinIO-
    /// instans på :9000), så den signerade headern måste matcha exakt
    /// (CodeRabbit-fynd, PR #90) annars underkänns signaturen av servern.
    // internal (inte `private`) enbart för att vara direkt testbar via
    // @testable import — inte del av den publika API-ytan.
    var host: String {
        guard let h = endpoint.host else { return "" }
        guard let port = endpoint.port else { return h }
        let defaultPort = endpoint.scheme == "https" ? 443 : 80
        return port == defaultPort ? h : "\(h):\(port)"
    }

    private func request(
        method: String,
        pathSegments: [String],
        queryItems: [(String, String)] = [],
        body: Data = Data(),
        contentType: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let path = pathSegments.isEmpty ? "/" : encodePath(pathSegments)
        let sortedQuery = queryItems.sorted { $0.0 < $1.0 }
        let queryString = sortedQuery.map { "\($0.0)=\(encodePathSegment($0.1))" }.joined(separator: "&")

        var components = URLComponents()
        components.scheme = endpoint.scheme
        components.host = endpoint.host
        components.port = endpoint.port
        components.percentEncodedPath = path
        if !queryString.isEmpty { components.percentEncodedQuery = queryString }
        guard let url = components.url else { throw S3Error.malformedResponse }

        let amzDate = AWSSigV4.isoDateFormatter()
        let signed = AWSSigV4.sign(
            method: method, host: host, path: path, queryString: queryString,
            payload: body, region: region, credentials: credentials, amzDate: amzDate)

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body.isEmpty ? nil : body
        req.setValue(signed.amzDate, forHTTPHeaderField: "x-amz-date")
        req.setValue(signed.contentSHA256, forHTTPHeaderField: "x-amz-content-sha256")
        req.setValue(signed.authorizationHeader, forHTTPHeaderField: "Authorization")
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw S3Error.malformedResponse }
            return (data, http)
        } catch let e as S3Error {
            throw e
        } catch {
            throw S3Error.transport("\(error)")
        }
    }

    private func requireSuccess(_ data: Data, _ response: HTTPURLResponse) throws {
        guard (200...299).contains(response.statusCode) else {
            let err = S3XMLParser.parseError(data)
            throw S3Error.httpError(status: response.statusCode, code: err.code, message: err.message)
        }
    }

    public func listBuckets() async throws -> [S3Bucket] {
        let (data, response) = try await request(method: "GET", pathSegments: [])
        try requireSuccess(data, response)
        return S3XMLParser.parseBuckets(data)
    }

    public func createBucket(_ name: String) async throws {
        let (data, response) = try await request(method: "PUT", pathSegments: [name])
        try requireSuccess(data, response)
    }

    public func deleteBucket(_ name: String) async throws {
        let (data, response) = try await request(method: "DELETE", pathSegments: [name])
        try requireSuccess(data, response)
    }

    public func listObjects(bucket: String, prefix: String? = nil) async throws -> [S3Object] {
        var query: [(String, String)] = [("list-type", "2")]
        if let prefix { query.append(("prefix", prefix)) }
        let (data, response) = try await request(method: "GET", pathSegments: [bucket], queryItems: query)
        try requireSuccess(data, response)
        return S3XMLParser.parseObjects(data)
    }

    public func putObject(bucket: String, key: String, data body: Data, contentType: String? = nil) async throws {
        let (data, response) = try await request(
            method: "PUT", pathSegments: [bucket, key], body: body, contentType: contentType)
        try requireSuccess(data, response)
    }

    public func getObject(bucket: String, key: String) async throws -> Data {
        let (data, response) = try await request(method: "GET", pathSegments: [bucket, key])
        try requireSuccess(data, response)
        return data
    }

    public func deleteObject(bucket: String, key: String) async throws {
        let (data, response) = try await request(method: "DELETE", pathSegments: [bucket, key])
        try requireSuccess(data, response)
    }
}

/// SAX-baserad XML-parsning (Foundation `XMLParser`, inget tredjeparts-
/// beroende) av S3:s standardsvarsformat. Delar samma element-vokabulär
/// mellan riktig AWS S3 och Ceph RGW (verifierat mot Hostups riktiga svar).
enum S3XMLParser {
    private final class BucketsDelegate: NSObject, XMLParserDelegate {
        var buckets: [S3Bucket] = []
        private var currentElement = ""
        private var currentName: String?
        private var currentDate: String?
        private var inBucket = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            currentElement = name
            if name == "Bucket" { inBucket = true; currentName = nil; currentDate = nil }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard inBucket else { return }
            switch currentElement {
            case "Name": currentName = (currentName ?? "") + string
            case "CreationDate": currentDate = (currentDate ?? "") + string
            default: break
            }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "Bucket" {
                if let currentName {
                    buckets.append(S3Bucket(name: currentName, creationDate: currentDate.flatMap(S3XMLParser.parseISODate)))
                }
                inBucket = false
            }
        }
    }

    private final class ObjectsDelegate: NSObject, XMLParserDelegate {
        var objects: [S3Object] = []
        private var currentElement = ""
        private var currentKey: String?
        private var currentSize: String?
        private var currentModified: String?
        private var inContents = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            currentElement = name
            if name == "Contents" { inContents = true; currentKey = nil; currentSize = nil; currentModified = nil }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard inContents else { return }
            switch currentElement {
            case "Key": currentKey = (currentKey ?? "") + string
            case "Size": currentSize = (currentSize ?? "") + string
            case "LastModified": currentModified = (currentModified ?? "") + string
            default: break
            }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "Contents" {
                if let currentKey {
                    objects.append(S3Object(
                        key: currentKey,
                        size: currentSize.flatMap(Int64.init) ?? 0,
                        lastModified: currentModified.flatMap(S3XMLParser.parseISODate)))
                }
                inContents = false
            }
        }
    }

    private final class ErrorDelegate: NSObject, XMLParserDelegate {
        var code = ""
        var message = ""
        private var currentElement = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            currentElement = name
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            switch currentElement {
            case "Code": code += string
            case "Message": message += string
            default: break
            }
        }
    }

    static func parseBuckets(_ data: Data) -> [S3Bucket] {
        let delegate = BucketsDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.buckets
    }

    static func parseObjects(_ data: Data) -> [S3Object] {
        let delegate = ObjectsDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.objects
    }

    static func parseError(_ data: Data) -> (code: String, message: String) {
        let delegate = ErrorDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return (delegate.code.isEmpty ? "Unknown" : delegate.code, delegate.message)
    }

    static func parseISODate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
