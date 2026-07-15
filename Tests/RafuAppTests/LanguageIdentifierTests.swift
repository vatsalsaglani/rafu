import Foundation
import Testing

@testable import RafuApp

@Test(
    "Recognized extensions map to their LSP languageId",
    arguments: [
        ("main.swift", "swift"),
        ("lib.rs", "rust"),
        ("main.go", "go"),
        ("app.ts", "typescript"),
        ("app.tsx", "typescriptreact"),
        ("app.js", "javascript"),
        ("app.mjs", "javascript"),
        ("app.cjs", "javascript"),
        ("app.jsx", "javascriptreact"),
        ("script.py", "python"),
        ("main.c", "c"),
        ("header.h", "c"),
        ("main.cpp", "cpp"),
        ("main.cc", "cpp"),
        ("main.cxx", "cpp"),
        ("header.hpp", "cpp"),
        ("README.md", "markdown"),
        ("README.markdown", "markdown"),
        ("package.json", "json"),
        ("config.yaml", "yaml"),
        ("config.yml", "yaml"),
    ]
)
func recognizedExtensionsMapToLanguageID(fileName: String, expectedLanguageID: String) {
    let url = URL(fileURLWithPath: "/workspace/\(fileName)")
    #expect(LanguageIdentifier.forURL(url) == expectedLanguageID)
}

@Test("Case is ignored when matching an extension")
func extensionMatchingIsCaseInsensitive() {
    let url = URL(fileURLWithPath: "/workspace/Main.SWIFT")
    #expect(LanguageIdentifier.forURL(url) == "swift")
}

@Test(
    "Unrecognized or missing extensions decline",
    arguments: ["notes.txt", "archive.zip", "Makefile", "no-extension"]
)
func unrecognizedExtensionsDecline(fileName: String) {
    let url = URL(fileURLWithPath: "/workspace/\(fileName)")
    #expect(LanguageIdentifier.forURL(url) == nil)
}
