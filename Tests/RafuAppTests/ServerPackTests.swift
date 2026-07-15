import Testing

@testable import RafuApp

@Suite("Server packs")
struct ServerPackTests {
    @Test("Every pack member id exists in the curated catalog")
    func everyMemberExistsInCatalog() {
        let catalogIDs = Set(CuratedCatalog.servers.map(\.id))
        for pack in ServerPack.all {
            for serverID in pack.serverIDs {
                #expect(
                    catalogIDs.contains(serverID), "\(pack.id) references unknown id \(serverID)")
            }
        }
    }

    @Test("A pack claiming a shared runtime has at least one nodeHosted member backing that claim")
    func sharedRuntimeClaimIsBackedByANodeHostedMember() {
        for pack in ServerPack.all where pack.sharedRuntime {
            let nodeHostedCount = pack.serverIDs.filter { serverID in
                CuratedCatalog.servers.first { $0.id == serverID }?.kind == .nodeHosted
            }.count
            #expect(nodeHostedCount >= 1)
        }
    }

    @Test("This increment ships exactly one Node-runtime-sharing pack as its batching example")
    func exactlyOneSharedRuntimePack() {
        let sharedRuntimePacks = ServerPack.all.filter(\.sharedRuntime)
        #expect(sharedRuntimePacks.count == 1)
    }

    @Test("No pack is empty")
    func noPackIsEmpty() {
        for pack in ServerPack.all {
            #expect(!pack.serverIDs.isEmpty)
        }
    }
}
