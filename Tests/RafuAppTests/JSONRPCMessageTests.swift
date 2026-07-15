import Foundation
import Testing

@testable import RafuApp

@Test("JSONRPCID decodes a bare integer and a bare string")
func jsonRPCIDDecodesIntegerAndString() throws {
    let decoder = JSONDecoder()
    #expect(try decoder.decode(JSONRPCID.self, from: Data("7".utf8)) == .number(7))
    #expect(try decoder.decode(JSONRPCID.self, from: Data(#""abc""#.utf8)) == .string("abc"))
}

@Test("JSONRPCID rejects booleans, fractional numbers, and null")
func jsonRPCIDRejectsInvalidShapes() {
    let decoder = JSONDecoder()
    #expect(throws: (any Error).self) {
        _ = try decoder.decode(JSONRPCID.self, from: Data("true".utf8))
    }
    #expect(throws: (any Error).self) {
        _ = try decoder.decode(JSONRPCID.self, from: Data("1.5".utf8))
    }
    #expect(throws: (any Error).self) {
        _ = try decoder.decode(JSONRPCID.self, from: Data("null".utf8))
    }
}

@Test("JSONRPCID round-trips through JSON for both cases")
func jsonRPCIDRoundTrips() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let numberID = JSONRPCID.number(42)
    let stringID = JSONRPCID.string("abc-123")
    #expect(try decoder.decode(JSONRPCID.self, from: encoder.encode(numberID)) == numberID)
    #expect(try decoder.decode(JSONRPCID.self, from: encoder.encode(stringID)) == stringID)
}

@Test("JSONRPCID works as a dictionary key for both cases")
func jsonRPCIDWorksAsDictionaryKey() {
    var map: [JSONRPCID: String] = [:]
    map[.number(1)] = "one"
    map[.string("abc")] = "letters"
    #expect(map[.number(1)] == "one")
    #expect(map[.string("abc")] == "letters")
    #expect(map[.number(2)] == nil)
}

@Test("JSONRPCErrorObject round-trips with and without a data payload")
func errorObjectRoundTrips() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let withData = JSONRPCErrorObject(code: -32000, message: "boom", data: .string("detail"))
    let withoutData = JSONRPCErrorObject(code: -32001, message: "boom2", data: nil)
    #expect(try decoder.decode(JSONRPCErrorObject.self, from: encoder.encode(withData)) == withData)
    #expect(
        try decoder.decode(JSONRPCErrorObject.self, from: encoder.encode(withoutData))
            == withoutData)
}

@Test("classify distinguishes requests, notifications, and responses")
func classifyRoutesEachShape() throws {
    let requestBody = try JSONEncoder().encode(
        JSONRPCRequest(id: .number(1), method: "initialize", params: nil))
    switch try JSONRPCIncomingMessage.classify(requestBody) {
    case .request(let request):
        #expect(request.method == "initialize")
        #expect(request.id == .number(1))
    default:
        Issue.record("Expected classify to route a request")
    }

    let notificationBody = try JSONEncoder().encode(
        JSONRPCNotification(method: "textDocument/publishDiagnostics", params: nil))
    switch try JSONRPCIncomingMessage.classify(notificationBody) {
    case .notification(let notification):
        #expect(notification.method == "textDocument/publishDiagnostics")
    default:
        Issue.record("Expected classify to route a notification")
    }

    struct RawResponse: Encodable {
        let jsonrpc = "2.0"
        let id: JSONRPCID
        let result: String
    }
    let responseBody = try JSONEncoder().encode(RawResponse(id: .string("r1"), result: "ok"))
    switch try JSONRPCIncomingMessage.classify(responseBody) {
    case .response(let id, let body):
        #expect(id == .string("r1"))
        let decoded = try JSONDecoder().decode(JSONRPCResponseEnvelope<String>.self, from: body)
        #expect(decoded.result == "ok")
    default:
        Issue.record("Expected classify to route a response")
    }
}

@Test("classify throws when a body has neither id nor method")
func classifyThrowsOnEmptyObject() {
    let body = Data("{}".utf8)
    #expect(
        throws: JSONRPCIncomingMessage.ClassificationError.malformedFrame(byteCount: body.count)
    ) {
        _ = try JSONRPCIncomingMessage.classify(body)
    }
}

@Test("JSONValue round-trips a nested document exercising every case")
func jsonValueRoundTripsNestedDocument() throws {
    let value = JSONValue.object([
        "name": .string("Rafu"),
        "count": .number(3),
        "enabled": .bool(true),
        "tags": .array([.string("a"), .string("b")]),
        "missing": .null,
    ])
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let roundTripped = try decoder.decode(JSONValue.self, from: encoder.encode(value))
    #expect(roundTripped == value)
}

@Test("Response envelope treats an explicit null result as present")
func responseEnvelopeDecodesNullResult() throws {
    let body = Data(#"{"jsonrpc":"2.0","id":1,"result":null}"#.utf8)
    let envelope = try JSONDecoder().decode(JSONRPCResponseEnvelope<JSONValue>.self, from: body)
    #expect(envelope.hasResult)
    #expect(envelope.result == .some(.null))
    #expect(envelope.error == nil)
}

@Test("Response envelope surfaces an error without a result key")
func responseEnvelopeDecodesErrorOnly() throws {
    let body = Data(
        #"{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Method not found"}}"#.utf8)
    let envelope = try JSONDecoder().decode(JSONRPCResponseEnvelope<JSONValue>.self, from: body)
    #expect(!envelope.hasResult)
    #expect(envelope.error?.code == JSONRPCErrorObject.methodNotFound)
}
