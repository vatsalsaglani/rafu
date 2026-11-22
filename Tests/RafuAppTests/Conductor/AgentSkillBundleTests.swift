import Foundation
import JSONRenderCore
import JSONRenderSwiftUI
import RafuCore
import Testing

@testable import RafuApp

/// An agent in an Ensemble terminal must never need Rafu's source. These tests
/// keep every skill the tool description and the skill text name in the
/// bundle, every manifest file on disk, and every JSON example valid.
@Suite("Bundled agent skills")
@MainActor
struct AgentSkillBundleTests {
    private static let jsonRenderSkill = "json-render-swift-use"

    private func catalogs() throws -> [ConductorBundledSkillCatalog] {
        try ConductorBundledSkillCatalog.bundledSkills()
    }

    private func text(_ catalog: ConductorBundledSkillCatalog, _ path: String) throws -> String {
        let file = ConductorBundledSkillFile(
            pathComponents: path.split(separator: "/").map(String.init))
        return String(decoding: try catalog.data(for: file), as: UTF8.self)
    }

    /// Skill-like names in `text`: `rafu-…` or `json-render-…`.
    private static func skillNames(in text: String) -> Set<String> {
        var names = Set<String>()
        let pattern = #"\b(?:rafu|json-render)(?:-[a-z]+)+\b"#
        var search = text.startIndex..<text.endIndex
        while let range = text.range(of: pattern, options: .regularExpression, range: search) {
            names.insert(String(text[range]))
            search = range.upperBound..<text.endIndex
        }
        return names
    }

    @Test("The catalog lists the four skills, json-render-swift-use and rafu-meetings among them")
    func skillList() {
        let names = ConductorBundledSkillCatalog.skills.map(\.identifier)
        #expect(names == ["rafu-ensemble", "rafu-view", Self.jsonRenderSkill, "rafu-meetings"])
    }

    @Test("The rafu-meetings skill names its three tools and the Settings switch")
    func meetingsSkill() throws {
        let meetings = try #require(try catalogs().first { $0.skill == "rafu-meetings" })
        let body = try text(meetings, "SKILL.md")
        for tool in ["meeting_access", "meeting_search", "meeting_read", "next_after"] {
            #expect(body.contains(tool), Comment(rawValue: tool))
        }
        #expect(body.contains("Settings ▸ Meetings ▸ Allow agents to read your meetings"))
        #expect(body.contains("Do not look for meeting files on disk"))
        #expect(!body.contains("Canvas") && !body.contains("Conductor"))
    }

    @Test("Every skill the view_render description and the rafu-view skill name is bundled")
    func namedSkillsAreBundled() throws {
        let bundled = Set(ConductorBundledSkillCatalog.skills.map(\.identifier))
        let render = try #require(
            CanvasAgentToolCatalog.definitions.first { $0["name"] as? String == "view_render" })
        let description = try #require(render["description"] as? String)
        let view = try #require(try catalogs().first { $0.skill == "rafu-view" })
        let skillText = try text(view, "SKILL.md")

        let named = Self.skillNames(in: description).union(Self.skillNames(in: skillText))
        #expect(named.contains(Self.jsonRenderSkill))
        #expect(named.contains("rafu-view"))
        for name in named {
            #expect(bundled.contains(name), Comment(rawValue: "\(name) is not bundled"))
        }
        #expect(description.contains("references/components.md"))
        #expect(skillText.contains("references/components.md"))
        #expect(skillText.contains("Do not read Rafu's source code"))
    }

    @Test("Every manifest file exists, is not empty and fits the limit; no resource is unlisted")
    func manifestsMatchResources() throws {
        for catalog in try catalogs() {
            for file in catalog.manifest {
                let data = try catalog.data(for: file)
                #expect(!data.isEmpty, Comment(rawValue: "\(catalog.skill)/\(file.relativePath)"))
            }
            let folder = catalog.resourceRootURL.appending(
                path: catalog.skill, directoryHint: .isDirectory)
            let onDisk = try Self.regularFiles(under: folder)
            let listed = Set(catalog.manifest.map(\.relativePath))
            #expect(onDisk == listed, Comment(rawValue: catalog.skill))
        }
    }

    private static func regularFiles(under folder: URL) throws -> Set<String> {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let walker = try #require(
            FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys))
        let base = folder.resolvingSymlinksInPath().path + "/"
        var result = Set<String>()
        for case let url as URL in walker
        where (try url.resourceValues(forKeys: Set(keys))).isRegularFile == true {
            let path = url.resolvingSymlinksInPath().path
            result.insert(String(path.dropFirst(base.count)))
        }
        return result
    }

    @Test("Each skill's frontmatter name equals its folder, and its relative links resolve")
    func frontmatterAndLinks() throws {
        for catalog in try catalogs() {
            let metadata = try catalog.metadata()
            #expect(metadata.name == catalog.skill)
            let listed = Set(catalog.manifest.map(\.relativePath))
            for file in catalog.manifest where file.relativePath.hasSuffix(".md") {
                let body = try text(catalog, file.relativePath)
                let parent = file.pathComponents.dropLast().joined(separator: "/")
                for target in Self.relativeLinks(in: body) {
                    let path = parent.isEmpty ? target : parent + "/" + target
                    #expect(
                        listed.contains(path),
                        Comment(
                            rawValue: "\(catalog.skill)/\(file.relativePath) links to \(target)"))
                }
            }
        }
    }

    /// The targets of `](relative/path.md)` links, without anchors.
    private static func relativeLinks(in text: String) -> [String] {
        var targets: [String] = []
        var search = text.startIndex..<text.endIndex
        while let range = text.range(
            of: #"\]\((?!https?:)[^)#\s]+\.md(?:#[^)]*)?\)"#, options: .regularExpression,
            range: search)
        {
            let match = text[range].dropFirst(2).dropLast()
            targets.append(String(match.prefix { $0 != "#" }))
            search = range.upperBound..<text.endIndex
        }
        return targets
    }

    @Test("The bundled upstream skill carries its licence and notice")
    func upstreamLicence() throws {
        let catalog = try #require(try catalogs().first { $0.skill == Self.jsonRenderSkill })
        #expect(try text(catalog, "LICENSE").contains("Apache License"))
        #expect(try text(catalog, "NOTICE").contains("swift-json-render"))
        #expect(try text(catalog, "SKILL.md").contains("0.22.0-alpha.3"))
    }

    // MARK: Examples

    /// The fenced ```json blocks of a Markdown file.
    private static func jsonBlocks(in text: String) -> [String] {
        var blocks: [String] = []
        var current: [Substring]?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current == nil {
                if line.hasPrefix("```json") { current = [] }
            } else if line.hasPrefix("```") {
                blocks.append(current?.joined(separator: "\n") ?? "")
                current = nil
            } else {
                current?.append(line)
            }
        }
        return blocks
    }

    @Test("Every Rafu component has a section in rafu-view references/components.md")
    func everyRafuComponentIsDocumented() throws {
        let view = try #require(try catalogs().first { $0.skill == "rafu-view" })
        let body = try text(view, "references/components.md")
        let standard = try Catalog.standard.merging(Catalog.charts)
        let rafuOnly = Set(RafuCatalog.rafu.componentNames).subtracting(standard.componentNames)
        #expect(rafuOnly.count == 17)
        for name in rafuOnly {
            #expect(body.contains("\n## \(name)\n"), Comment(rawValue: name))
        }
    }

    @Test("Every JSON example in rafu-view validates with the view_render validator")
    func examplesValidate() throws {
        let view = try #require(try catalogs().first { $0.skill == "rafu-view" })
        let host = GeneratedViewActions()
        for path in ["references/components.md", "references/examples.md", "SKILL.md"] {
            let blocks = Self.jsonBlocks(in: try text(view, path))
            #expect(!blocks.isEmpty, Comment(rawValue: path))
            for (index, block) in blocks.enumerated() {
                let result = host.validate(specJSON: block)
                if case .failure(let error) = result {
                    Issue.record("\(path) example \(index + 1): \(error)")
                }
            }
        }
    }

    @Test("Each Rafu component's example in components.md renders as its own type")
    func componentExamplesUseTheirType() throws {
        let view = try #require(try catalogs().first { $0.skill == "rafu-view" })
        let body = try text(view, "references/components.md")
        let sections = body.components(separatedBy: "\n## ").dropFirst()
        let host = GeneratedViewActions()
        for section in sections {
            let name = String(section.prefix { $0 != "\n" })
            let block = try #require(Self.jsonBlocks(in: section).first, Comment(rawValue: name))
            guard case .success(let summary) = host.validate(specJSON: block) else {
                Issue.record("\(name) example does not validate")
                continue
            }
            #expect(summary.types.contains(name), Comment(rawValue: name))
        }
    }
}
