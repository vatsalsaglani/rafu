import Foundation
import Testing

@testable import RafuCore

@Suite("Workspace file format")
struct WorkspaceFileFormatTests {
    private func sample() -> RafuWorkspaceFile {
        RafuWorkspaceFile(
            displayName: "Shop",
            folders: [
                .init(bookmark: Data([1, 2, 3]), lastKnownPath: "/work/web"),
                .init(bookmark: nil, lastKnownPath: "/work/api"),
            ],
            primaryIndex: 1)
    }

    @Test("A file round-trips and keeps the primary folder")
    func roundTrip() throws {
        let data = try sample().encoded()
        let decoded = try RafuWorkspaceFile.decode(data)
        #expect(decoded == sample())
        #expect(decoded.formatVersion == 1)
        #expect(decoded.orderedFolders.map(\.lastKnownPath) == ["/work/api", "/work/web"])
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"formatVersion\" : 1"))
        #expect(text.contains("\"lastKnownPath\" : \"/work/web\""))
    }

    @Test("A newer format version is refused with a clear message")
    func futureVersion() throws {
        let json = #"{"formatVersion": 2, "displayName": "X", "folders": []}"#
        #expect(throws: RafuWorkspaceFileError.unsupportedVersion(2)) {
            try RafuWorkspaceFile.decode(Data(json.utf8))
        }
        let message = RafuWorkspaceFileError.unsupportedVersion(2).errorDescription ?? ""
        #expect(message.contains("format 2"))
        #expect(message.contains("Update Rafu"))
    }

    @Test("Files over 1 MiB are refused before parsing")
    func sizeBound() {
        let data = Data(repeating: 0x20, count: RafuWorkspaceFile.maximumBytes + 1)
        #expect(throws: RafuWorkspaceFileError.tooLarge(byteCount: data.count)) {
            try RafuWorkspaceFile.decode(data)
        }
    }

    @Test("Malformed content is refused")
    func malformed() {
        let cases = [
            "not json",
            #"{"displayName": "X", "folders": []}"#,
            #"{"formatVersion": 0, "displayName": "X", "folders": []}"#,
            #"{"formatVersion": 1, "displayName": "X"}"#,
            #"{"formatVersion": 1, "displayName": "X", "folders": [{"lastKnownPath": "rel"}]}"#,
        ]
        for json in cases {
            #expect(throws: RafuWorkspaceFileError.self) {
                try RafuWorkspaceFile.decode(Data(json.utf8))
            }
        }
        #expect(throws: RafuWorkspaceFileError.noFolders) {
            try RafuWorkspaceFile.decode(
                Data(#"{"formatVersion": 1, "displayName": "X", "folders": []}"#.utf8))
        }
    }

    @Test("A bad primary index falls back to the first folder; names are cleaned")
    func lenientFields() throws {
        let json = #"""
            {"formatVersion": 1, "displayName": "  Two\nLines  ", "primaryIndex": 7,
             "folders": [{"lastKnownPath": "/a"}, {"lastKnownPath": "/b"}],
             "futureField": true}
            """#
        let file = try RafuWorkspaceFile.decode(Data(json.utf8))
        #expect(file.primaryIndex == nil)
        #expect(file.displayName == "Two Lines")
        #expect(file.orderedFolders.map(\.lastKnownPath) == ["/a", "/b"])
    }

    @Test("Too many folders are refused")
    func folderLimit() {
        let folders = (0...WorkspaceRootList.maximumRoots).map {
            RafuWorkspaceFile.Folder(bookmark: nil, lastKnownPath: "/f/\($0)")
        }
        #expect(throws: RafuWorkspaceFileError.tooManyFolders(folders.count)) {
            try RafuWorkspaceFile(displayName: "X", folders: folders).encoded()
        }
    }

    @Test("Display names come from the file name")
    func namesFromFileName() {
        #expect(RafuWorkspaceFile.displayName(forFileName: "Shop.rafuworkspace") == "Shop")
        #expect(RafuWorkspaceFile.displayName(forFileName: ".rafuworkspace") == ".rafuworkspace")
        #expect(RafuWorkspaceFile.cleanedName("   ") == "Workspace")
    }
}
