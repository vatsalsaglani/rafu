import CoreGraphics
import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Canvas diagram model")
struct CanvasDiagramModelTests {
    @Test("Frames and service icons round-trip and validate their bounds")
    func roundTrip() throws {
        let frame = CanvasFrame(title: "Backend", memberIDs: [CanvasCardID()], style: .blue)
        let data = try JSONEncoder().encode(frame)
        #expect(try JSONDecoder().decode(CanvasFrame.self, from: data) == frame)
        try frame.validate()

        let icon = CanvasServiceIcon(packID: "aws", iconID: "compute-amazon-ec2", label: "EC2")
        #expect(
            try JSONDecoder().decode(
                CanvasServiceIcon.self, from: JSONEncoder().encode(icon)) == icon)
        try icon.validate()

        #expect(throws: CanvasDiagramError.self) {
            try CanvasFrame(title: " ").validate()
        }
        let id = CanvasCardID()
        #expect(throws: CanvasDiagramError.self) {
            try CanvasFrame(title: "Twice", memberIDs: [id, id]).validate()
        }
        #expect(throws: CanvasDiagramError.self) {
            try CanvasServiceIcon(packID: "../aws", iconID: "x", label: "").validate()
        }
        #expect(throws: CanvasDiagramError.self) {
            try CanvasServiceIcon(
                packID: "aws", iconID: "x", label: String(repeating: "a", count: 121)
            ).validate()
        }
    }

    @Test("An unknown frame style from a newer build reads as neutral")
    func unknownStyle() throws {
        let json = #"{"title":"A","memberIDs":[],"style":"plaid"}"#
        let frame = try JSONDecoder().decode(CanvasFrame.self, from: Data(json.utf8))
        #expect(frame.style == .neutral)
    }

    @Test("Slugs are identifiers")
    func slugs() {
        #expect(CanvasDiagramText.slug("Amazon EC2") == "amazon-ec2")
        #expect(CanvasDiagramText.slug("AI + Machine Learning") == "ai-machine-learning")
        #expect(CanvasDiagramText.slug("***") == "icon")
        #expect(CanvasDiagramText.isIdentifier(CanvasDiagramText.slug("Café Ünïcode")))
    }

    @Test("The built-in Common pack manifest is valid and covers the core services")
    func commonPack() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/RafuApp/Resources/DiagramPacks/common.json")
        let pack = try CanvasCommonIconPack.decode(Data(contentsOf: url))
        try pack.validate()
        #expect(pack.id == CanvasCommonIconPack.packID)
        #expect(pack.entries.count >= 40)
        #expect(pack.entries.allSatisfy { $0.symbol != nil && $0.file == nil })
        let names = Set(pack.entries.map(\.id))
        for required in [
            "user", "browser", "mobile-app", "api", "server", "function", "container",
            "database", "cache", "queue", "stream", "object-storage", "cdn", "dns",
            "load-balancer", "api-gateway", "auth", "monitoring",
        ] {
            #expect(names.contains(required), "missing \(required)")
        }
    }
}

@Suite("Canvas icon search")
struct CanvasIconSearchTests {
    private let pack = CanvasIconPack(
        id: "test", name: "Test", vendor: .custom,
        entries: [
            .init(
                id: "db", name: "Database", category: "Data", keywords: ["sql", "postgres"],
                symbol: "cylinder"),
            .init(
                id: "cache", name: "Cache", category: "Data", keywords: ["redis"], symbol: "bolt"),
            .init(
                id: "lb", name: "Load Balancer", category: "Networking",
                keywords: ["alb", "nlb"], symbol: "arrow"),
            .init(
                id: "sqs", name: "Simple Queue Service", category: "Integration",
                keywords: [], symbol: "tray"),
            .init(
                id: "dbmig", name: "Database Migration Service", category: "Data",
                keywords: [], symbol: "arrow"),
        ])

    @Test("An exact name beats a longer name with the same prefix")
    func exactFirst() {
        let index = CanvasIconSearchIndex(packs: [pack])
        let results = index.search("database")
        #expect(results.map(\.entry.id) == ["db", "dbmig"])
        #expect(results[0].score > results[1].score)
    }

    @Test("Keywords, initials, prefixes and subsequences match; misses do not")
    func matching() {
        let index = CanvasIconSearchIndex(packs: [pack])
        #expect(index.search("redis").first?.entry.id == "cache")
        #expect(index.search("sqs").first?.entry.id == "sqs")
        let aws = CanvasIconSearchIndex(packs: [
            CanvasIconPack(
                id: "aws", name: "AWS", vendor: .aws,
                entries: [
                    .init(
                        id: "sqs", name: "Amazon Simple Queue Service", category: "Integration",
                        file: "sqs.svg")
                ])
        ])
        #expect(aws.search("sqs").first?.entry.id == "sqs")
        #expect(index.search("load bal").first?.entry.id == "lb")
        #expect(index.search("LOAD").first?.entry.id == "lb")
        #expect(index.search("ldblncr").first?.entry.id == "lb")
        #expect(index.search("kubernetes").isEmpty)
        // Every word must match.
        #expect(index.search("database redis").isEmpty)
    }

    @Test("Empty queries list entries in pack order and limits apply")
    func emptyAndLimit() {
        let index = CanvasIconSearchIndex(packs: [pack])
        #expect(index.search("", limit: 2).map(\.entry.id) == ["db", "cache"])
        #expect(index.search("a", limit: 1).count == 1)
        #expect(index.search("a", limit: 0).isEmpty)
    }

    @Test("Search over a few thousand icons is fast")
    func speed() {
        let entries = (0..<6_000).map {
            CanvasIconPackEntry(
                id: "icon-\($0)", name: "Service Number \($0)", category: "Category \($0 % 20)",
                keywords: ["alpha", "beta"], symbol: "circle")
        }
        let index = CanvasIconSearchIndex(packs: [
            CanvasIconPack(id: "big", name: "Big", vendor: .custom, entries: entries)
        ])
        let start = Date()
        for query in ["service", "num 59", "srvnmbr", "zzz"] { _ = index.search(query) }
        #expect(Date().timeIntervalSince(start) < 2)
    }
}

@Suite("Canvas icon pack layout")
struct CanvasIconPackLayoutTests {
    private let aws = [
        "Asset-Package/Architecture-Service-Icons_07312024/Arch_Compute/Arch_32/Arch_Amazon-EC2_32.svg",
        "Asset-Package/Architecture-Service-Icons_07312024/Arch_Compute/Arch_64/Arch_Amazon-EC2_64.svg",
        "Asset-Package/Architecture-Service-Icons_07312024/Arch_Compute/Arch_64/Arch_Amazon-EC2_64.png",
        "Asset-Package/Architecture-Service-Icons_07312024/Arch_Analytics/Arch_48/Arch_Amazon-Athena_48.svg",
        "Asset-Package/Resource-Icons_07312024/Res_Compute/Res_48_Light/Res_Amazon-EC2_Instance_48_Light.svg",
        "Asset-Package/Resource-Icons_07312024/Res_Compute/Res_48_Dark/Res_Amazon-EC2_Instance_48_Dark.svg",
        "__MACOSX/Asset-Package/._Arch_Amazon-EC2_64.svg",
        "Asset-Package/README.txt",
    ]
    private let azure = [
        "Azure_Public_Service_Icons/Icons/compute/10021-icon-service-Virtual-Machine.svg",
        "Azure_Public_Service_Icons/Icons/ai + machine learning/10162-icon-service-Cognitive-Services.svg",
        "Azure_Public_Service_Icons/Icons/databases/10130-icon-service-SQL-Database.svg",
    ]
    private let google = [
        "Google Cloud Icons/BigQuery/SVG/BigQuery-512-color.svg",
        "Google Cloud Icons/BigQuery/PNG/BigQuery-512-color.png",
        "Unique Icons/Cloud Run/SVG/CloudRun-512-color.svg",
        "Unique Icons/Security Operations/SVG/SecOps-512-color-rgb.svg",
        "Unique Icons/Cloud Run/.DS_Store",
    ]

    @Test("Each vendor layout is detected; an unknown tree is custom")
    func detection() {
        #expect(CanvasIconPackLayout.detectVendor(paths: aws) == .aws)
        #expect(CanvasIconPackLayout.detectVendor(paths: azure) == .azure)
        #expect(CanvasIconPackLayout.detectVendor(paths: google) == .googleCloud)
        #expect(CanvasIconPackLayout.detectVendor(paths: ["mine/icons/rocket.svg"]) == .custom)
        #expect(CanvasIconPackLayout.detectVendor(paths: []) == .custom)
    }

    @Test("AWS names, categories and size de-duplication")
    func awsCandidates() {
        let candidates = CanvasIconPackLayout.candidates(paths: aws, vendor: .aws)
        let names = candidates.map { "\($0.entry.category)/\($0.entry.name)" }
        #expect(
            names == [
                "Analytics/Amazon Athena", "Compute/Amazon EC2", "Compute/Amazon EC2 Instance",
            ])
        #expect(
            CanvasIconPackLayout.displayName(fileName: "Arch_AWS-Lambda_64@5x.png", vendor: .aws)
                == "AWS Lambda")
        let ec2 = candidates.first { $0.entry.name == "Amazon EC2" }
        #expect(ec2?.sourcePath.hasSuffix("Arch_Amazon-EC2_64.svg") == true)
        let instance = candidates.first { $0.entry.name == "Amazon EC2 Instance" }
        #expect(instance?.sourcePath.contains("Light") == true)
        #expect(ec2?.entry.keywords.contains("aws") == true)
        #expect(ec2?.entry.file == "compute-amazon-ec2.svg")
    }

    @Test("Azure and Google Cloud names and categories")
    func otherVendors() {
        let azureNames = CanvasIconPackLayout.candidates(paths: azure, vendor: .azure).map {
            "\($0.entry.category)/\($0.entry.name)"
        }
        #expect(azureNames.contains("Compute/Virtual Machine"))
        #expect(azureNames.contains("AI + Machine Learning/Cognitive Services"))
        #expect(azureNames.contains("Databases/SQL Database"))

        let googleCandidates = CanvasIconPackLayout.candidates(paths: google, vendor: .googleCloud)
        #expect(
            googleCandidates.map(\.entry.name).sorted() == [
                "BigQuery", "Cloud Run", "Security Operations",
            ])
        #expect(googleCandidates.allSatisfy { $0.fileExtension == "svg" })
        #expect(googleCandidates.allSatisfy { $0.entry.category == "Google Cloud" })
        #expect(
            CanvasIconPackLayout.displayName(fileName: "SecOps-512-color-rgb.svg", vendor: .custom)
                == "SecOps")
    }

    @Test("Icon ids stay unique and every entry validates")
    func uniqueIDs() throws {
        let paths = ["a/Thing.svg", "a/thing.png", "b/Thing.svg", "b/Thing-2.svg"]
        let candidates = CanvasIconPackLayout.candidates(paths: paths, vendor: .custom)
        #expect(Set(candidates.map(\.entry.id)).count == candidates.count)
        for candidate in candidates { try candidate.entry.validate() }
    }
}

@Suite("Canvas icon pack safety")
struct CanvasIconPackSafetyTests {
    @Test("Archive entries that escape the extraction folder are rejected")
    func archiveEntries() {
        #expect(CanvasIconPackSafety.isSafeArchiveEntry("Icons/compute/vm.svg"))
        #expect(CanvasIconPackSafety.isSafeArchiveEntry("Icons/"))
        #expect(!CanvasIconPackSafety.isSafeArchiveEntry("../evil.svg"))
        #expect(!CanvasIconPackSafety.isSafeArchiveEntry("Icons/../../evil.svg"))
        #expect(!CanvasIconPackSafety.isSafeArchiveEntry("/etc/passwd"))
        #expect(!CanvasIconPackSafety.isSafeArchiveEntry("~/evil"))
        #expect(!CanvasIconPackSafety.isSafeArchiveEntry("C:/evil"))
        #expect(!CanvasIconPackSafety.isSafeArchiveEntry("Icons\\..\\evil"))
        #expect(!CanvasIconPackSafety.isSafeArchiveEntry("a\u{0}b"))
        #expect(!CanvasIconPackSafety.isSafeArchiveEntry("a\nb"))
        #expect(!CanvasIconPackSafety.isSafeArchiveEntry(""))
    }

    @Test("zipinfo totals parse")
    func totals() {
        let output =
            "Archive:  x.zip\n1234 files, 56789012 bytes uncompressed, 1234 bytes compressed:  73.0%\n"
        let totals = CanvasIconPackSafety.zipTotals(output)
        #expect(totals?.entries == 1_234)
        #expect(totals?.uncompressedBytes == 56_789_012)
        #expect(
            CanvasIconPackSafety.zipTotals(
                "1 file, 10 bytes uncompressed, 10 bytes compressed:  0.0%")?.entries == 1)
        #expect(CanvasIconPackSafety.zipTotals("garbage") == nil)
    }

    @Test("SVG content with scripts or external references is rejected")
    func svgPolicy() {
        func ok(_ text: String) -> Bool { CanvasIconPackSafety.isAcceptableSVG(Data(text.utf8)) }
        #expect(ok(#"<svg xmlns="http://www.w3.org/2000/svg"><path d="M0 0"/></svg>"#))
        #expect(!ok(#"<svg><script>alert(1)</script></svg>"#))
        #expect(!ok(#"<svg onload="x()"></svg>"#))
        #expect(!ok(#"<svg><a href="javascript:x"/></svg>"#))
        #expect(!ok(#"<svg><image href="https://example.com/a.png"/></svg>"#))
        #expect(!ok(#"<svg><foreignObject/></svg>"#))
        #expect(!ok("not an svg"))
        #expect(
            CanvasIconPackSafety.isPNG(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0])))
        #expect(!CanvasIconPackSafety.isPNG(Data("<svg".utf8)))
    }
}

@Suite("Canvas frames")
struct CanvasFrameLayoutTests {
    private func rect(_ x: Double, _ y: Double, _ w: Double = 120, _ h: Double = 100) -> CanvasRect
    {
        CanvasRect(x: x, y: y, width: w, height: h)
    }

    @Test("A frame encloses its members with padding and a title band")
    func enclosing() throws {
        let frame = try #require(
            CanvasFrameLayout.enclosingRect([rect(100, 200), rect(300, 260, 100, 80)]))
        #expect(frame.x == 100 - CanvasFrameLayout.padding)
        #expect(frame.y == 200 - CanvasFrameLayout.padding - CanvasFrameLayout.titleBand)
        #expect(frame.width == 300 + 2 * CanvasFrameLayout.padding)
        #expect(
            frame.height == 140 + 2 * CanvasFrameLayout.padding + CanvasFrameLayout.titleBand)
        #expect(CanvasFrameLayout.enclosingRect([]) == nil)
        let huge = try #require(
            CanvasFrameLayout.enclosingRect([rect(0, 0), rect(5_000, 5_000)]))
        #expect(huge.isValid)
    }

    @Test("The agent-side frame preview matches the app's frame rect")
    func agentBoundsMatch() throws {
        let rects = [rect(100, 200), rect(300, 260, 100, 80), rect(-40, 500, 160, 128)]
        let app = try #require(CanvasFrameLayout.enclosingRect(rects))
        let agent = try #require(
            CanvasAgentDiagramLayout.bounds(
                rects.map {
                    CanvasAgentRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                }))
        #expect(CanvasRect(x: agent.x, y: agent.y, width: agent.width, height: agent.height) == app)
        #expect(CanvasAgentDiagramLayout.framePadding == CanvasFrameLayout.padding)
        #expect(CanvasAgentDiagramLayout.frameTitleBand == CanvasFrameLayout.titleBand)
    }

    @Test("Moving a frame moves its members, nested members too, and nothing else")
    func frameMove() {
        let a = CanvasCardID()
        let b = CanvasCardID()
        let c = CanvasCardID()
        let inner = CanvasCardID()
        let outer = CanvasCardID()
        let nodes: [CanvasFrameLayout.Node] = [
            .init(id: outer, rect: rect(0, 0, 800, 600), frameMembers: [inner, a]),
            .init(id: inner, rect: rect(10, 10, 300, 300), frameMembers: [b]),
            .init(id: a, rect: rect(400, 50)),
            .init(id: b, rect: rect(20, 60)),
            .init(id: c, rect: rect(1_000, 1_000)),
        ]
        let moves = CanvasFrameLayout.frameMove(outer, dx: 10, dy: -5, in: nodes)
        #expect(Set(moves.keys) == [outer, inner, a, b])
        #expect(moves[b] == rect(30, 55))
        #expect(CanvasFrameLayout.frameMove(inner, dx: 1, dy: 1, in: nodes).count == 2)
        #expect(CanvasFrameLayout.closure(of: [c], in: nodes) == [c])
    }

    @Test("Membership cycles end")
    func cycles() {
        let a = CanvasCardID()
        let b = CanvasCardID()
        let nodes: [CanvasFrameLayout.Node] = [
            .init(id: a, rect: rect(0, 0), frameMembers: [b]),
            .init(id: b, rect: rect(0, 0), frameMembers: [a]),
        ]
        #expect(CanvasFrameLayout.closure(of: [a], in: nodes) == [a, b])
        #expect(CanvasFrameLayout.stackedFramesBehindMembers(nodes).count == 2)
    }

    @Test("Members follow a frame moved alone, but not one that moved with it")
    func follow() {
        let frame = CanvasCardID()
        let member = CanvasCardID()
        let other = CanvasCardID()
        let old: [CanvasFrameLayout.Node] = [
            .init(id: frame, rect: rect(0, 0, 400, 300), frameMembers: [member, other]),
            .init(id: member, rect: rect(20, 60)), .init(id: other, rect: rect(200, 60)),
        ]
        var moved = old
        moved[0].rect = rect(50, 20, 400, 300)
        let followed = CanvasFrameLayout.followed(moved, previous: old)
        #expect(followed[1].rect == rect(70, 80))
        #expect(followed[2].rect == rect(250, 80))

        var joint = moved
        joint[1].rect = rect(70, 80)
        let jointFollowed = CanvasFrameLayout.followed(joint, previous: old)
        #expect(jointFollowed[1].rect == rect(70, 80))
        #expect(jointFollowed[2].rect == rect(250, 80))

        // An agent that sets x, y, width and height still moves the members.
        var placed = old
        placed[0].rect = rect(-10, 0, 900, 900)
        #expect(CanvasFrameLayout.followed(placed, previous: old)[1].rect == rect(10, 60))
        #expect(CanvasFrameLayout.followed(old, previous: old) == old)
    }

    @Test("Frames fit their members, inner frames first; an empty frame keeps its rect")
    func fitted() throws {
        let a = CanvasCardID()
        let b = CanvasCardID()
        let inner = CanvasCardID()
        let outer = CanvasCardID()
        let empty = CanvasCardID()
        let nodes: [CanvasFrameLayout.Node] = [
            .init(id: outer, rect: rect(0, 0, 200, 200), frameMembers: [inner, a]),
            .init(id: inner, rect: rect(900, 900, 200, 200), frameMembers: [b]),
            .init(id: empty, rect: rect(5, 5, 300, 300), frameMembers: [CanvasCardID()]),
            .init(id: a, rect: rect(400, 100)),
            .init(id: b, rect: rect(100, 300)),
        ]
        let result = CanvasFrameLayout.fitted(nodes)
        let innerRect = try #require(CanvasFrameLayout.enclosingRect([rect(100, 300)]))
        #expect(result[1].rect == innerRect)
        #expect(result[0].rect == CanvasFrameLayout.enclosingRect([innerRect, rect(400, 100)]))
        #expect(result[2].rect == rect(5, 5, 300, 300))
        #expect(CanvasFrameLayout.fitted(result) == result)
    }

    @Test("Normalizing follows, fits and stacks in one pass")
    func normalized() throws {
        let frame = CanvasCardID()
        let a = CanvasCardID()
        let b = CanvasCardID()
        let fit = try #require(CanvasFrameLayout.enclosingRect([rect(0, 0), rect(300, 0)]))
        let old: [CanvasFrameLayout.Node] = [
            .init(id: frame, rect: fit, frameMembers: [a, b]),
            .init(id: a, rect: rect(0, 0)), .init(id: b, rect: rect(300, 0)),
        ]
        // A member that moves grows the frame.
        var memberMoved = old
        memberMoved[2].rect = rect(600, 50)
        let grown = CanvasFrameLayout.normalized(memberMoved, previous: old)
        #expect(grown[0].rect == CanvasFrameLayout.enclosingRect([rect(0, 0), rect(600, 50)]))
        // A frame raised to the front goes back behind its members.
        let raised = [old[1], old[2], old[0]]
        #expect(CanvasFrameLayout.normalized(raised, previous: old).map(\.id) == [frame, a, b])
        // A frame moved alone carries its members, and the refit is a no-op.
        var frameMoved = old
        frameMoved[0].rect = CanvasFrameLayout.moved(fit, dx: 40, dy: 8)
        let carried = CanvasFrameLayout.normalized(frameMoved, previous: old)
        #expect(carried[0].rect == CanvasFrameLayout.moved(fit, dx: 40, dy: 8))
        #expect(carried[1].rect == rect(40, 8))
        #expect(carried[2].rect == rect(340, 8))
    }

    @Test("Frames stack just behind their earliest member; correct orders are kept")
    func stacking() {
        let a = CanvasCardID()
        let b = CanvasCardID()
        let c = CanvasCardID()
        let frame = CanvasCardID()
        let order: [CanvasFrameLayout.Node] = [
            .init(id: a, rect: rect(0, 0)), .init(id: b, rect: rect(0, 0)),
            .init(id: c, rect: rect(0, 0)),
            .init(id: frame, rect: rect(0, 0), frameMembers: [c, b]),
        ]
        let stacked = CanvasFrameLayout.stackedFramesBehindMembers(order)
        #expect(stacked.map(\.id) == [a, frame, b, c])
        #expect(CanvasFrameLayout.stackedFramesBehindMembers(stacked) == stacked)
    }
}

@Suite("Canvas diagram export planning")
struct CanvasDiagramExportPlanTests {
    @Test("Targets select the board, a frame with members, or the selection with frame members")
    func targets() {
        let a = CanvasCardID()
        let b = CanvasCardID()
        let frame = CanvasCardID()
        let nodes: [CanvasFrameLayout.Node] = [
            .init(id: frame, rect: CanvasRect(), frameMembers: [a]),
            .init(id: a, rect: CanvasRect()), .init(id: b, rect: CanvasRect()),
        ]
        #expect(
            CanvasDiagramExportPlan.cardIDs(for: .board, nodes: nodes, selection: [])
                == [a, b, frame])
        #expect(
            CanvasDiagramExportPlan.cardIDs(for: .frame(frame), nodes: nodes, selection: [])
                == [a, frame])
        #expect(
            CanvasDiagramExportPlan.cardIDs(for: .frame(b), nodes: nodes, selection: []).isEmpty)
        #expect(
            CanvasDiagramExportPlan.cardIDs(for: .selection, nodes: nodes, selection: [frame, b])
                == [a, b, frame])
    }

    @Test("Bounds pad the union and the pixel scale respects the caps")
    func bounds() throws {
        let bounds = try #require(
            CanvasDiagramExportPlan.bounds(
                of: [
                    CanvasRect(x: 10, y: 20, width: 100, height: 100),
                    CanvasRect(x: 300, y: 50, width: 100, height: 200),
                ], padding: 40))
        #expect(bounds == CGRect(x: -30, y: -20, width: 470, height: 310))
        #expect(CanvasDiagramExportPlan.bounds(of: []) == nil)
        #expect(CanvasDiagramExportPlan.pngScale(for: bounds, requested: 2) == 2)
        let wide = CGRect(x: 0, y: 0, width: 4_000, height: 500)
        #expect(CanvasDiagramExportPlan.gifScale(for: wide) == 0.4)
        #expect(CanvasDiagramExportPlan.pngScale(for: wide, requested: 3) == 1.024)
        #expect(CanvasDiagramExportPlan.pngScale(for: bounds, requested: .nan) == 1)
        let huge = CGRect(x: 0, y: 0, width: 200_000, height: 180_000)
        #expect(huge.width * CanvasDiagramExportPlan.pngScale(for: huge, requested: 3) <= 4_096)
        #expect(huge.width * CanvasDiagramExportPlan.gifScale(for: huge) <= 1_600)
    }

    @Test("Export file names are safe and stay inside the workspace")
    func names() {
        let date = Date(timeIntervalSince1970: 0)
        let name = CanvasDiagramExportPlan.fileName(
            boardTitle: "A/B: C", targetName: "board", format: .gif(seconds: 3, fps: 12),
            date: date)
        #expect(!name.contains("/") && !name.contains(":"))
        #expect(name.hasSuffix(".gif"))
        let root = URL(fileURLWithPath: "/tmp/rafu-root", isDirectory: true)
        #expect(
            CanvasDiagramExportPlan.isInside(root.appending(path: "exports/a.png"), root: root))
        #expect(!CanvasDiagramExportPlan.isInside(URL(fileURLWithPath: "/tmp/other"), root: root))
        #expect(
            !CanvasDiagramExportPlan.isInside(
                URL(fileURLWithPath: "/tmp/rafu-root-2/a.png"), root: root))
    }

    @Test("GIF plans cap frames and keep the delay in hundredths")
    func gifPlan() {
        let plan = CanvasGIFPlan(seconds: 3, fps: 15)
        #expect(plan.frameCount == 45)
        #expect(plan.delay == 0.07)
        #expect(CanvasGIFPlan(seconds: 60, fps: 60).frameCount == CanvasGIFPlan.maximumFrames)
        #expect(CanvasGIFPlan(seconds: 0, fps: 1).frameCount >= 2)
        #expect(plan.progress(ofFrame: 0) == 0)
        #expect(plan.progress(ofFrame: 45) == 0)
        #expect(plan.progress(ofFrame: 9) == 0.2)
    }

    @Test("Dots travel by arc length, in the edge's direction, and message links go both ways")
    func dots() throws {
        let path = CanvasFlowPath(points: [
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100),
        ])
        #expect(path.length == 200)
        #expect(path.point(atFraction: 0.25) == CGPoint(x: 50, y: 0))
        #expect(path.point(atFraction: 0.75) == CGPoint(x: 100, y: 50))
        #expect(path.point(atFraction: 2) == CGPoint(x: 100, y: 100))

        let id = UUID()
        let one = CanvasGIFFlow.dots(
            for: [.init(id: id, path: path, bidirectional: false)], progress: 0)
        #expect(one == [.init(edgeID: id, point: .zero, forward: true)])
        let middle = CanvasGIFFlow.dots(
            for: [.init(id: id, path: path, bidirectional: false)], progress: 0.5)
        #expect(middle.first?.point == CGPoint(x: 100, y: 0))
        // Easing: a quarter of the time covers less than a quarter of the path.
        let early = try #require(
            CanvasGIFFlow.dots(
                for: [.init(id: id, path: path, bidirectional: false)], progress: 0.25
            ).first)
        #expect(early.point.x < 50)

        let both = CanvasGIFFlow.dots(
            for: [.init(id: id, path: path, bidirectional: true)], progress: 0)
        #expect(both.count == 2)
        #expect(both[1].forward == false)
        #expect(both[1].point == CGPoint(x: 100, y: 0))

        let curve = CanvasEdgeCurve(
            start: .zero, control1: CGPoint(x: 50, y: 0), control2: CGPoint(x: 50, y: 100),
            end: CGPoint(x: 100, y: 100))
        let curved = CanvasFlowPath(curve: curve)
        #expect(curved.point(atFraction: 0) == .zero)
        #expect(curved.point(atFraction: 1) == CGPoint(x: 100, y: 100))
        #expect(CanvasGIFFlow.dots(for: [], progress: 0.3).isEmpty)
    }
}

@Suite("Mermaid export preparation")
@MainActor
struct CanvasMermaidExportTests {
    @Test("Exports prepare bounded diagram pixels before taking a static snapshot")
    func preparesImages() async throws {
        let valid = CanvasCard(title: "Flow", content: .mermaid(source: "flowchart LR\n A --> B"))
        let invalid = CanvasCard(title: "Invalid", content: .mermaid(source: "not a diagram"))
        let snapshots = try await CanvasMermaidExportSnapshot.prepare(
            cards: [valid, invalid], theme: MermaidThemeSpec(theme: RafuThemeCatalog.indigo))
        let image = try #require(snapshots[valid.id]?.image)
        #expect(image.width > 0 && image.height > 0)
        #expect(image.width <= 1_024 && image.height <= 1_024)
        #expect(snapshots[valid.id]?.failure == nil)
        #expect(snapshots[invalid.id]?.image == nil)
        #expect(snapshots[invalid.id]?.failure != nil)
    }
}

@Suite("Canvas export file writes")
struct CanvasExportWriterTests {
    @Test("New exports work through a workspace symlink; escaping export folders are refused")
    func workspaceAliases() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let root = base.appending(path: "workspace")
        let alias = base.appending(path: "alias")
        let outside = base.appending(path: "outside")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: root)
        let bytes = Data("test export".utf8)
        let result = try await CanvasDiagramExportWriter.write(
            bytes, fileName: "test.png", root: alias)
        #expect(try Data(contentsOf: result) == bytes)
        #expect(CanvasDiagramExportPlan.isInside(result, root: root))
        try fm.removeItem(at: root.appending(path: "exports"))
        try fm.createSymbolicLink(at: root.appending(path: "exports"), withDestinationURL: outside)
        await #expect(throws: CanvasDiagramError.self) {
            try await CanvasDiagramExportWriter.write(bytes, fileName: "escape.png", root: alias)
        }
        #expect(!fm.fileExists(atPath: outside.appending(path: "escape.png").path))
    }
}

@Suite("Canvas frame bounds on a board")
@MainActor
struct CanvasFrameBoardTests {
    private func rect(_ x: Double, _ y: Double) -> CanvasRect {
        CanvasRect(x: x, y: y, width: 160, height: 128)
    }

    private func makeBoard() throws -> (CanvasBoardState, CanvasCardID, CanvasCardID, CanvasCardID) {
        var document = CanvasDocument(title: "Diagram")
        let a = CanvasCard(title: "A", rect: rect(0, 0), content: .text(CanvasText(text: "A")))
        let b = CanvasCard(title: "B", rect: rect(400, 0), content: .text(CanvasText(text: "B")))
        document.cards = [a, b]
        let board = CanvasBoardState(document: document)
        let frame = try #require(try board.createFrame(title: "Group", memberIDs: [a.id, b.id]))
        return (board, frame, a.id, b.id)
    }

    private func frameRect(_ board: CanvasBoardState, _ id: CanvasCardID) -> CanvasRect? {
        board.cards.first { $0.id == id }?.rect
    }

    private func fit(_ board: CanvasBoardState, _ ids: [CanvasCardID]) -> CanvasRect? {
        CanvasFrameLayout.enclosingRect(board.cards.filter { ids.contains($0.id) }.map(\.rect))
    }

    @Test("A member move refits the frame in the same undo step")
    func memberMove() throws {
        let (board, frame, a, b) = try makeBoard()
        let before = frameRect(board, frame)
        board.select([b])
        try board.moveSelection(dx: 0, dy: 300)
        #expect(frameRect(board, frame) == fit(board, [a, b]))
        #expect(frameRect(board, frame) != before)
        board.performUndo()
        #expect(frameRect(board, frame) == before)
        #expect(board.cards.first { $0.id == b }?.rect == rect(400, 0))
    }

    @Test("A member resize and a member removal refit the frame")
    func memberResizeAndRemove() throws {
        let (board, frame, a, b) = try makeBoard()
        board.beginGesture()
        board.setRect(CanvasRect(x: 400, y: 0, width: 600, height: 500), for: b)
        board.endGesture()
        #expect(frameRect(board, frame) == fit(board, [a, b]))
        let grown = frameRect(board, frame)
        board.select([b])
        try board.removeSelection()
        #expect(frameRect(board, frame) == fit(board, [a]))
        board.performUndo()
        #expect(frameRect(board, frame) == grown)
    }

    @Test("Moving the frame moves its members; resizing a frame does nothing")
    func frameMoveAndResize() throws {
        let (board, frame, a, b) = try makeBoard()
        let before = try #require(frameRect(board, frame))
        board.select([frame])
        try board.moveSelection(dx: 24, dy: 16)
        #expect(board.cards.first { $0.id == a }?.rect == rect(24, 16))
        #expect(board.cards.first { $0.id == b }?.rect == rect(424, 16))
        #expect(frameRect(board, frame) == CanvasFrameLayout.moved(before, dx: 24, dy: 16))
        let moved = frameRect(board, frame)
        try board.resizeSelection(dw: 80, dh: 80)
        #expect(frameRect(board, frame) == moved)
        #expect(board.cards.first?.id == frame)
    }

    @Test("Nested frames fit inner first, and an outer move carries everything")
    func nested() throws {
        let (board, inner, a, b) = try makeBoard()
        let outer = try #require(try board.createFrame(title: "Outer", memberIDs: [inner]))
        #expect(frameRect(board, outer) == fit(board, [inner]))
        #expect(board.cards.map(\.id).prefix(2) == [outer, inner])
        board.select([a])
        try board.moveSelection(dx: -200, dy: 0)
        #expect(frameRect(board, inner) == fit(board, [a, b]))
        #expect(frameRect(board, outer) == fit(board, [inner]))
        try board.moveFrame(outer, by: CGSize(width: 0, height: 40))
        #expect(board.cards.first { $0.id == b }?.rect == rect(400, 40))
        #expect(frameRect(board, outer) == fit(board, [inner]))
    }
}
