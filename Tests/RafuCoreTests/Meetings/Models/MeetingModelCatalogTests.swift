import Foundation
import Testing

@testable import RafuCore

@Suite("Meeting model catalog")
struct MeetingModelCatalogTests {
    private static func isHex(_ text: String, count: Int) -> Bool {
        text.count == count && text.allSatisfy { "0123456789abcdef".contains($0) }
    }

    @Test("Each model has one complete entry")
    func eachModelHasAnEntry() {
        #expect(MeetingModelCatalog.entries.map(\.id) == MeetingModelID.allCases)
        for model in MeetingModelID.allCases {
            #expect(MeetingModelCatalog.entry(for: model).id == model)
        }
    }

    @Test("Each entry has a pinned revision, a licence, an attribution, and checked files")
    func entriesAreComplete() throws {
        for entry in MeetingModelCatalog.entries {
            #expect(Self.isHex(entry.revision, count: 40), "\(entry.id)")
            #expect(!entry.displayName.isEmpty)
            #expect(!entry.licenseName.isEmpty)
            #expect(entry.licenseURL.hasPrefix("https://"))
            #expect(!entry.attribution.isEmpty)
            #expect(!entry.repository.isEmpty)
            #expect(!entry.files.isEmpty)
            for file in entry.files {
                #expect(Self.isHex(file.revision, count: 40), "\(file.remotePath)")
                #expect(Self.isHex(file.sha256, count: 64), "\(file.remotePath)")
                #expect(file.bytes > 0, "\(file.remotePath)")
                let url = try #require(file.downloadURL)
                #expect(
                    url.absoluteString
                        == "https://huggingface.co/\(file.repository)/resolve/\(file.revision)/\(file.remotePath)"
                )
            }
            #expect(throws: Never.self) { try MeetingModelVerifier.checkCatalogPaths(entry) }
            #expect(entry.totalBytes == entry.files.reduce(0) { $0 + $1.bytes })
        }
    }

    @Test("The pins of the plan's model table")
    func pins() {
        let nemotron = MeetingModelCatalog.entry(for: .nemotronEnglish1120)
        #expect(nemotron.repository == "FluidInference/nemotron-speech-streaming-en-0.6b-coreml")
        #expect(nemotron.revision == "0651794847e50f9687bcaa096c3f8ec696ac6fc4")
        #expect(nemotron.licenseName == "NVIDIA Open Model License")
        #expect(
            nemotron.attribution
                == "Licensed by NVIDIA Corporation under the NVIDIA Open Model License")

        let whisper = MeetingModelCatalog.entry(for: .whisperLargeV3)
        #expect(whisper.revision == "0f63a7800b00dd0226abd051b906c246e1907482")
        let tokenizer = whisper.files.filter { $0.repository == "openai/whisper-large-v3" }
        #expect(tokenizer.map(\.localPath).sorted() == ["tokenizer.json", "tokenizer_config.json"])
        #expect(tokenizer.allSatisfy { $0.revision == "06f233fe06e710322aca913c1bc4249a0d71fce1" })
        #expect(
            whisper.files.filter { $0.repository == "argmaxinc/whisperkit-coreml" }.count == 17)

        let diarization = MeetingModelCatalog.entry(for: .nemotron3Fast32)
        #expect(diarization.repository == "FluidInference/nemotron-3-diarization-coreml")
        #expect(diarization.revision == "25a90f97f254428d4b30374b76af9c74fdee8327")
        #expect(diarization.licenseName == "OpenMDW License v1.1")

        let speakerKit = MeetingModelCatalog.entry(for: .speakerKit)
        #expect(speakerKit.repository == "argmaxinc/speakerkit-coreml")
        #expect(speakerKit.revision == "556fc52a13327837688f02289457cded017802e9")
        #expect(speakerKit.licenseName == "CC BY 4.0")
        #expect(speakerKit.files.count == 20)
    }

    @Test("The SHA-256 values that the speech spike recorded")
    func spikeHashes() {
        func hash(_ model: MeetingModelID, _ localPath: String) -> String? {
            MeetingModelCatalog.entry(for: model).files.first { $0.localPath == localPath }?.sha256
        }
        let bundle = "Nemotron3Diarizer_fast32.mlmodelc"
        #expect(
            hash(.nemotron3Fast32, "\(bundle)/weights/weight.bin")
                == "7353d8e7a5d29a8d15edf86dbf40bed4e82b7b8f456f302d5cdcbf850ed25358")
        #expect(
            hash(.nemotron3Fast32, "\(bundle)/coremldata.bin")
                == "fbc2d4dc25147427269e4774a5b8e3dd6b613e8c8458d74c7462a1a377dbae75")
        #expect(
            hash(.nemotron3Fast32, "\(bundle)/analytics/coremldata.bin")
                == "7932ba85d07f09ba8feff996e1278f376a9139e31141d2827021f1c225e590ae")
        #expect(
            hash(.nemotron3Fast32, "learnable_sil_emb.bin")
                == "d4417b3c0eabdf7c47032fac2b5b5a7ee83d819a6ddda8fd8eaf74e2b5cc4ac7")
        #expect(
            hash(.nemotron3Fast32, "\(bundle)/model.mil")
                == "e2f0cbbf88e824385475779b637c36281c5f98f339783840bdf7b3dfcd08c123")
        #expect(
            hash(
                .speakerKit,
                "speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter.mlmodelc/weights/weight.bin")
                == "75ff1725ef4e58dacf9176466ec274a8a13a6132c296d6b571fb78ddad5455c4")
        #expect(
            hash(
                .speakerKit,
                "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder.mlmodelc/weights/weight.bin")
                == "a02861969f47cf3a67e3b0d276e54b3c8bc3a6e43d40d77d1cccbd57da0e5795")
        #expect(
            hash(
                .speakerKit,
                "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedderPreprocessor.mlmodelc/weights/weight.bin"
            )
                == "5f2c284bd22f1f7ab76901c1c6e57f82d4ebbf057fa0b924aad057f124f77a89")
        #expect(
            hash(
                .speakerKit,
                "speaker_clusterer/pyannote-v4/W32A32/PldaProjector.mlmodelc/weights/weight.bin")
                == "a1dbbb651a0a67fcfe5334672f459df090fa960917a6ee3a5423245a7ab92ced")
    }

    @Test("Download sizes (exact bytes)")
    func sizes() {
        #expect(MeetingModelCatalog.entry(for: .nemotronEnglish1120).totalBytes == 626_200_525)
        #expect(MeetingModelCatalog.entry(for: .whisperLargeV3).totalBytes == 629_481_698)
        #expect(MeetingModelCatalog.entry(for: .nemotron3Fast32).totalBytes == 199_070_892)
        #expect(MeetingModelCatalog.entry(for: .speakerKit).totalBytes == 11_242_906)
    }

    // MARK: Golden local layouts (the layouts that each load call needs)

    @Test("Nemotron English: flat folder, v2 encoder in encoder/, no preprocessor")
    func nemotronLayout() {
        let paths = Set(MeetingModelCatalog.entry(for: .nemotronEnglish1120).files.map(\.localPath))
        #expect(
            paths == [
                "decoder.mlmodelc/analytics/coremldata.bin",
                "decoder.mlmodelc/coremldata.bin",
                "decoder.mlmodelc/model.mil",
                "decoder.mlmodelc/weights/weight.bin",
                "decoder_joint.mlmodelc/analytics/coremldata.bin",
                "decoder_joint.mlmodelc/coremldata.bin",
                "decoder_joint.mlmodelc/model.mil",
                "decoder_joint.mlmodelc/weights/weight.bin",
                "encoder/encoder_int8_v2.mlmodelc/analytics/coremldata.bin",
                "encoder/encoder_int8_v2.mlmodelc/coremldata.bin",
                "encoder/encoder_int8_v2.mlmodelc/model.mil",
                "encoder/encoder_int8_v2.mlmodelc/weights/weight.bin",
                "joint.mlmodelc/analytics/coremldata.bin",
                "joint.mlmodelc/coremldata.bin",
                "joint.mlmodelc/model.mil",
                "joint.mlmodelc/weights/weight.bin",
                "metadata.json",
                "tokenizer.json",
            ])
        let remote = MeetingModelCatalog.entry(for: .nemotronEnglish1120).files.map(\.remotePath)
        #expect(remote.allSatisfy { !$0.contains("preprocessor") })
        #expect(remote.allSatisfy { !$0.hasPrefix("nemotron_coreml_1120ms/encoder/") })
        #expect(remote.filter { $0.hasPrefix("encoder-v2/1120ms/") }.count == 4)
    }

    @Test("WhisperKit: one flat folder with the tokenizer files beside the bundles")
    func whisperLayout() {
        let paths = Set(MeetingModelCatalog.entry(for: .whisperLargeV3).files.map(\.localPath))
        #expect(
            paths == [
                "AudioEncoder.mlmodelc/analytics/coremldata.bin",
                "AudioEncoder.mlmodelc/coremldata.bin",
                "AudioEncoder.mlmodelc/metadata.json",
                "AudioEncoder.mlmodelc/model.mil",
                "AudioEncoder.mlmodelc/weights/weight.bin",
                "MelSpectrogram.mlmodelc/analytics/coremldata.bin",
                "MelSpectrogram.mlmodelc/coremldata.bin",
                "MelSpectrogram.mlmodelc/metadata.json",
                "MelSpectrogram.mlmodelc/model.mil",
                "MelSpectrogram.mlmodelc/weights/weight.bin",
                "TextDecoder.mlmodelc/analytics/coremldata.bin",
                "TextDecoder.mlmodelc/coremldata.bin",
                "TextDecoder.mlmodelc/metadata.json",
                "TextDecoder.mlmodelc/model.mil",
                "TextDecoder.mlmodelc/weights/weight.bin",
                "config.json",
                "generation_config.json",
                "tokenizer.json",
                "tokenizer_config.json",
            ])
    }

    @Test("Nemotron 3: the bundle and learnable_sil_emb.bin side by side")
    func diarizationLayout() {
        let entry = MeetingModelCatalog.entry(for: .nemotron3Fast32)
        #expect(
            Set(entry.files.map(\.localPath)) == [
                "Nemotron3Diarizer_fast32.mlmodelc/analytics/coremldata.bin",
                "Nemotron3Diarizer_fast32.mlmodelc/coremldata.bin",
                "Nemotron3Diarizer_fast32.mlmodelc/model.mil",
                "Nemotron3Diarizer_fast32.mlmodelc/weights/weight.bin",
                "learnable_sil_emb.bin",
            ])
        let bundleFiles = entry.files.filter { $0.localPath.hasPrefix("Nemotron3Diarizer") }
        #expect(bundleFiles.allSatisfy { $0.remotePath.hasPrefix("monolithic/v2/") })
    }

    @Test("SpeakerKit: the same nested tree as the repository")
    func speakerKitLayout() {
        let entry = MeetingModelCatalog.entry(for: .speakerKit)
        #expect(entry.files.allSatisfy { $0.localPath == $0.remotePath })
        let bundles = Set(
            entry.files.map { file in
                file.localPath.components(separatedBy: ".mlmodelc").first ?? ""
            })
        #expect(
            bundles == [
                "speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter",
                "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder",
                "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedderPreprocessor",
                "speaker_clusterer/pyannote-v4/W32A32/PldaProjector",
            ])
        let names = [
            "analytics/coremldata.bin", "coremldata.bin", "metadata.json", "model.mil",
            "weights/weight.bin",
        ]
        for bundle in bundles {
            for name in names {
                #expect(entry.files.contains { $0.localPath == "\(bundle).mlmodelc/\(name)" })
            }
        }
    }

    // MARK: Files that Rafu writes

    @Test("The licence, notice and marker texts")
    func installFiles() {
        let entry = MeetingModelCatalog.entry(for: .whisperLargeV3)
        let license = MeetingModelInstallFiles.licenseText(for: entry)
        #expect(license.contains(entry.licenseName))
        #expect(license.contains(entry.licenseURL))
        #expect(license.contains("argmaxinc/whisperkit-coreml @ \(entry.revision)"))
        #expect(
            license.contains("openai/whisper-large-v3 @ 06f233fe06e710322aca913c1bc4249a0d71fce1"))
        #expect(MeetingModelInstallFiles.noticeText(for: entry) == entry.attribution + "\n")
        #expect(MeetingModelInstallFiles.markerText(for: entry) == entry.revision + "\n")
        let folder = MeetingModelInstallFiles.installFolder(
            modelsRoot: URL(fileURLWithPath: "/tmp/Models"), entry: entry)
        #expect(folder.path == "/tmp/Models/whisperkit-large-v3-626mb/\(entry.revision)")
    }
}
