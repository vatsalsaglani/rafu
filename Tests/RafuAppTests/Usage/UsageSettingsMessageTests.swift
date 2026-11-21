import Testing

@testable import RafuApp

@Test("The denied text tells the person to choose Allow")
func deniedMessageTellsThePersonToChooseAllow() {
    #expect(
        UsageConnectionIssueText.credentialAccessDenied
            == "Connection failed: you denied Keychain access. Connect again and choose Allow.")
}

@Test("The Keychain error text shows the real status number")
func keychainErrorMessageShowsTheStatus() {
    let text = UsageConnectionIssueText.keychainError(-67_062)
    #expect(text.contains("error -67062"))
    #expect(text.contains("quit and reopen it"))
    #expect(!text.contains("denied"))
}
