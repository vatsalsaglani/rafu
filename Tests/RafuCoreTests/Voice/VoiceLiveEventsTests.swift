import Foundation
import Testing

@testable import RafuCore

private func object(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

@Suite("Voice live events")
struct VoiceLiveEventsTests {
    private static let noteTool = VoiceFunctionTool(
        name: "note_create", description: "…",
        parameters: [
            "type": "object", "properties": ["title": ["type": "string"]],
            "required": ["title"], "additionalProperties": false,
        ])

    @Test("session.start encodes exactly the Phase 0 shape")
    func sessionStartShape() throws {
        let config = VoiceSessionConfig(
            instructions: "…", voice: .marin,
            delegation: VoiceDelegationConfig(
                model: "gpt-6.1-terra", instructions: "…", tools: [Self.noteTool]))
        let text = try VoiceLiveClientEvent.sessionStart(config).json(eventID: "evt_x")
        let expected = """
            {"event_id":"evt_x","session":{"audio":{"output":{"voice":"marin"}},"delegation":{"responses":{"instructions":"…","model":"gpt-6.1-terra","parallel_tool_calls":false,"tool_choice":"auto","tools":[{"description":"…","name":"note_create","parameters":{"additionalProperties":false,"properties":{"title":{"type":"string"}},"required":["title"],"type":"object"},"type":"function"}]},"type":"responses"},"instructions":"…","model":"gpt-live-1"},"type":"session.start"}
            """
        #expect(text == expected)
    }

    @Test("Client events carry type and event_id with the documented fields")
    func clientEventShapes() throws {
        let audio = try object(
            VoiceLiveClientEvent.inputAudioAppend(Data([1, 2, 3, 4])).json(eventID: "evt_a"))
        #expect(audio["type"] as? String == "session.input_audio.append")
        #expect(audio["audio"] as? String == Data([1, 2, 3, 4]).base64EncodedString())
        #expect(audio["event_id"] as? String == "evt_a")
        #expect(audio.count == 3)

        let output = try object(
            VoiceLiveClientEvent.responseItemCreateFunctionOutput(callID: "call_1", output: "{}")
                .json())
        let item = try #require(output["item"] as? [String: Any])
        #expect(output["type"] as? String == "response.item.create")
        #expect(item["type"] as? String == "function_call_output")
        #expect(item["call_id"] as? String == "call_1")
        #expect(item["output"] as? String == "{}")

        for (event, type) in [
            (VoiceLiveClientEvent.responseCreate, "response.create"),
            (.sessionClose, "session.close"), (.inputAudioMute, "session.input_audio.mute"),
            (.inputAudioUnmute, "session.input_audio.unmute"),
        ] {
            let decoded = try object(event.json())
            #expect(decoded["type"] as? String == type)
            #expect((decoded["event_id"] as? String)?.hasPrefix("evt_") == true)
            #expect(decoded.count == 2)
        }

        let commentary = try object(
            VoiceLiveClientEvent.commentaryAppend(delegationID: nil, "Still there?").json())
        #expect(commentary["delegation_id"] == nil)
        #expect(commentary["content"] as? String == "Still there?")

        let update = try object(
            VoiceLiveClientEvent.sessionUpdate(
                VoiceDelegationConfig(model: "gpt-6-luna", instructions: "x", tools: [])
            ).json())
        let delegation = try #require(
            (update["session"] as? [String: Any])?["delegation"] as? [String: Any])
        #expect(delegation["type"] as? String == "responses")
        #expect((delegation["responses"] as? [String: Any])?["model"] as? String == "gpt-6-luna")
    }

    @Test("Fresh event ids differ")
    func eventIDs() {
        #expect(VoiceLiveClientEvent.newEventID() != VoiceLiveClientEvent.newEventID())
    }

    @Test("Every Phase 0 server event decodes")
    func decodesServerEvents() {
        let pcm = Data([0, 1, 2, 3])
        let cases: [(String, VoiceLiveServerEvent)] = [
            (
                #"{"type":"session.started","client_event_id":"evt_x","session":{"id":"sess_1","expires_at":1767225600,"model":"gpt-live-1","status":"active","input":[]}}"#,
                .sessionStarted(id: "sess_1", expiresAt: 1_767_225_600)
            ),
            (
                #"{"type":"session.output_audio.delta","delta":"\#(pcm.base64EncodedString())"}"#,
                .outputAudioDelta(pcm)
            ),
            (
                #"{"type":"session.input_transcript.delta","delta":"add","start_ms":0,"end_ms":40}"#,
                .inputTranscriptDelta("add")
            ),
            (
                #"{"type":"session.output_transcript.delta","delta":"Done","start_ms":0,"end_ms":40}"#,
                .outputTranscriptDelta("Done")
            ),
            (
                #"{"type":"session.delegation.created","offset_ms":10,"delegation":{"id":"del_1","type":"delegation","target":"responses","response_id":"resp_1"}}"#,
                .delegationCreated(id: "del_1", target: "responses")
            ),
            (
                #"{"type":"response.event","delegation_id":"del_1","event":{"type":"response.output_item.done","sequence_number":4,"item":{"type":"function_call","call_id":"call_1","name":"note_create","arguments":"{\"title\":\"Plan\"}"}}}"#,
                .functionCall(
                    callID: "call_1", name: "note_create", argumentsJSON: #"{"title":"Plan"}"#)
            ),
            (
                #"{"type":"response.event","delegation_id":"del_1","event":{"type":"response.completed","response":{"id":"resp_1","status":"completed","usage":{"input_tokens":900,"output_tokens":20}}}}"#,
                .responseCompleted(inputTokens: 900, outputTokens: 20)
            ),
            (
                #"{"type":"session.updated","client_event_id":"evt_y","session":{}}"#,
                .sessionUpdated
            ),
            (
                #"{"type":"session.commentary.appended","client_event_id":"evt_z","start_ms":0,"end_ms":10}"#,
                .commentaryAppended
            ),
            (
                #"{"type":"session.usage.updated","usage":{"seconds":15.5},"context_window":{"usage_ratio":0.01}}"#,
                .usageUpdated(seconds: 15.5, contextRatio: 0.01)
            ),
            (
                #"{"type":"session.closed","reason":"close_requested","usage":{"seconds":42},"session":{}}"#,
                .sessionClosed(reason: "close_requested", seconds: 42)
            ),
            (
                #"{"type":"error","error":{"type":"invalid_request_error","code":"forbidden","message":"Voice session access denied.","param":null}}"#,
                .error(code: "forbidden", message: "Voice session access denied.")
            ),
        ]
        for (text, expected) in cases {
            #expect(VoiceLiveServerEvent.decode(text) == expected, Comment(rawValue: text))
        }
    }

    @Test("Unknown types become other; nested noise is filtered by its type")
    func filtersNoise() {
        #expect(
            VoiceLiveServerEvent.decode(#"{"type":"session.thinking"}"#)
                == .other("session.thinking"))
        #expect(
            VoiceLiveServerEvent.decode(
                #"{"type":"response.event","event":{"type":"response.output_item.done","item":{"type":"reasoning","encrypted_content":"AAAA"}}}"#
            ) == .other("response.event/response.output_item.done"))
        #expect(
            VoiceLiveServerEvent.decode(
                #"{"type":"response.event","event":{"type":"response.created","response":{"instructions":"long"}}}"#
            ) == .other("response.event/response.created"))
        #expect(VoiceLiveServerEvent.decode("not json") == nil)
    }
}
