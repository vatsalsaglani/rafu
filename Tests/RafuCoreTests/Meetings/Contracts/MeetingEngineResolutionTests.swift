import Testing

@testable import RafuCore

@Suite("Meeting contracts: engine choice")
struct MeetingEngineResolutionTests {
    /// Each availability a test row can give an engine.
    private static let states: [MeetingEngineAvailability] = [
        .ready, .needsModel([.nemotronEnglish1120]),
        .unavailable(reason: "Meetings needs macOS 26"),
    ]

    private static func textTables() -> [[MeetingTextEngineID: MeetingEngineAvailability]] {
        var tables: [[MeetingTextEngineID: MeetingEngineAvailability]] = []
        for nemotron in states {
            for apple in states {
                for whisper in states {
                    tables.append([
                        .nemotronEnglish: nemotron, .appleSpeech: apple, .whisperKit: whisper,
                    ])
                }
            }
        }
        tables.append([:])
        return tables
    }

    @Test("Final text: the preferred engine when ready, else Apple speech")
    func finalText() {
        for preference in MeetingTextEngineID.allCases {
            for table in Self.textTables() {
                let expected: MeetingTextEngineID =
                    table[preference] == .ready ? preference : .appleSpeech
                #expect(
                    resolvedFinalTextEngine(preference: preference, availability: table)
                        == expected,
                    "\(preference) \(table)")
            }
        }
    }

    @Test("Live text: preferred when ready and live, else Nemotron when ready, else Apple speech")
    func liveText() {
        for preference in MeetingTextEngineID.allCases {
            for table in Self.textTables() {
                let expected: MeetingTextEngineID
                if table[preference] == .ready, preference != .whisperKit {
                    expected = preference
                } else if table[.nemotronEnglish] == .ready {
                    expected = .nemotronEnglish
                } else {
                    expected = .appleSpeech
                }
                #expect(
                    resolvedLiveTextEngine(preference: preference, availability: table) == expected,
                    "\(preference) \(table)")
            }
        }
        // WhisperKit never gives live text, even when it is the only ready one.
        #expect(
            resolvedLiveTextEngine(
                preference: .whisperKit,
                availability: [.whisperKit: .ready, .nemotronEnglish: .needsModel([])])
                == .appleSpeech)
    }

    @Test("Speakers: preferred when ready, else the other when ready, else none")
    func speakers() {
        for preference in MeetingSpeakerEngineID.allCases {
            let other: MeetingSpeakerEngineID = preference == .nemotron3 ? .speakerKit : .nemotron3
            for mine in Self.states {
                for theirs in Self.states {
                    let table = [preference: mine, other: theirs]
                    let expected: MeetingSpeakerEngineID? =
                        mine == .ready ? preference : (theirs == .ready ? other : nil)
                    #expect(
                        resolvedSpeakerEngine(preference: preference, availability: table)
                            == expected, "\(preference) \(table)")
                }
            }
            #expect(resolvedSpeakerEngine(preference: preference, availability: [:]) == nil)
        }
    }
}
