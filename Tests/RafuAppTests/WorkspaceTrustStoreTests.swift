import Foundation
import Testing

@testable import RafuApp

@Suite("Workspace trust store")
struct WorkspaceTrustStoreTests {
    @Test("A server is untrusted until explicitly approved")
    func untrustedUntilApproved() async throws {
        try await withTemporaryDirectory { directory in
            let store = WorkspaceTrustStore(baseDirectory: directory)
            #expect(
                try await store.isTrusted(serverID: "rust-analyzer", forWorkspaceKey: "ws-1")
                    == false)

            try await store.approve(serverID: "rust-analyzer", forWorkspaceKey: "ws-1")
            #expect(
                try await store.isTrusted(serverID: "rust-analyzer", forWorkspaceKey: "ws-1")
                    == true)
        }
    }

    @Test("Trust is scoped per workspace key")
    func trustIsScopedPerWorkspace() async throws {
        try await withTemporaryDirectory { directory in
            let store = WorkspaceTrustStore(baseDirectory: directory)
            try await store.approve(serverID: "clangd", forWorkspaceKey: "ws-a")

            #expect(try await store.isTrusted(serverID: "clangd", forWorkspaceKey: "ws-a") == true)
            #expect(try await store.isTrusted(serverID: "clangd", forWorkspaceKey: "ws-b") == false)
        }
    }

    @Test("Revoking removes only the revoked server id")
    func revokeRemovesOnlyThatServer() async throws {
        try await withTemporaryDirectory { directory in
            let store = WorkspaceTrustStore(baseDirectory: directory)
            try await store.approve(serverID: "clangd", forWorkspaceKey: "ws-1")
            try await store.approve(serverID: "rust-analyzer", forWorkspaceKey: "ws-1")

            try await store.revoke(serverID: "clangd", forWorkspaceKey: "ws-1")

            #expect(try await store.isTrusted(serverID: "clangd", forWorkspaceKey: "ws-1") == false)
            #expect(
                try await store.isTrusted(serverID: "rust-analyzer", forWorkspaceKey: "ws-1")
                    == true)
        }
    }

    @Test("Revoking an id that was never approved is a no-op")
    func revokingUnapprovedIDIsNoOp() async throws {
        try await withTemporaryDirectory { directory in
            let store = WorkspaceTrustStore(baseDirectory: directory)
            try await store.revoke(serverID: "clangd", forWorkspaceKey: "ws-1")
            #expect(try await store.isTrusted(serverID: "clangd", forWorkspaceKey: "ws-1") == false)
        }
    }

    @Test("Approvals persist atomically across store instances in the same directory")
    func approvalsPersistAcrossInstances() async throws {
        try await withTemporaryDirectory { directory in
            try await WorkspaceTrustStore(baseDirectory: directory)
                .approve(serverID: "pyright", forWorkspaceKey: "ws-1")

            let reloaded = WorkspaceTrustStore(baseDirectory: directory)
            #expect(
                try await reloaded.isTrusted(serverID: "pyright", forWorkspaceKey: "ws-1") == true)
        }
    }
}
