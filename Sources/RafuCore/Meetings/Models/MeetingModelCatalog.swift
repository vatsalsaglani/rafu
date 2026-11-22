import Foundation

// The meeting model catalog: data only. Each downloadable model has a pinned
// Hugging Face revision (a commit, so its bytes cannot change), its licence
// name and attribution line (Settings ▸ Meetings and the first-use sheet show
// them before a download), and each file with its exact size and SHA-256.
//
// Where the values come from (a developer step on 2026-11-23, not run by the
// app): for an LFS file, the `lfs.oid` and `size` of the Hugging Face tree
// API at the pinned revision; for a small git file, its own SHA-256 after its
// git blob id was checked against the tree API. The script and its notes are
// in `Tests/RafuCoreTests/Meetings/Models/Support/catalog-hashes.sh.txt`.

/// One file of a model: where it comes from and where it goes.
public struct MeetingModelFile: Hashable, Sendable {
    /// The Hugging Face repository, for example `argmaxinc/speakerkit-coreml`.
    public var repository: String
    /// The pinned commit of `repository` (40 hexadecimal characters).
    public var revision: String
    /// The path in the repository.
    public var remotePath: String
    /// The path inside the installed model folder (the layout the load call needs).
    public var localPath: String
    /// The exact size in bytes. A download stops when it passes this size.
    public var bytes: Int64
    /// The SHA-256 of the file, lowercase hexadecimal (64 characters).
    public var sha256: String

    public init(
        repository: String, revision: String, remotePath: String, localPath: String,
        bytes: Int64, sha256: String
    ) {
        self.repository = repository
        self.revision = revision
        self.remotePath = remotePath
        self.localPath = localPath
        self.bytes = bytes
        self.sha256 = sha256
    }

    /// `https://huggingface.co/<repository>/resolve/<revision>/<remote path>`.
    /// It holds the pinned revision and no user value.
    public var downloadURL: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(repository)/resolve/\(revision)/\(remotePath)"
        return components.url
    }
}

/// One downloadable model.
public struct MeetingModelCatalogEntry: Hashable, Sendable, Identifiable {
    public var id: MeetingModelID
    /// The name in Settings, for example "Nemotron English".
    public var displayName: String
    /// The licence name to show before a download, for example
    /// "NVIDIA Open Model License".
    public var licenseName: String
    /// Where the licence text is published.
    public var licenseURL: String
    /// The attribution line to show before a download and in the `NOTICE` file.
    public var attribution: String
    /// The main repository; the install folder uses `revision`.
    public var repository: String
    /// The pinned commit of `repository`.
    public var revision: String
    public var files: [MeetingModelFile]

    public init(
        id: MeetingModelID, displayName: String, licenseName: String, licenseURL: String,
        attribution: String, repository: String, revision: String, files: [MeetingModelFile]
    ) {
        self.id = id
        self.displayName = displayName
        self.licenseName = licenseName
        self.licenseURL = licenseURL
        self.attribution = attribution
        self.repository = repository
        self.revision = revision
        self.files = files
    }

    /// The sum of the file sizes: the download size to show.
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    /// The size in the decimal form that macOS shows (example: "626.2 MB").
    public var totalSizeText: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

/// The four downloadable models. Apple speech needs no Rafu download.
public enum MeetingModelCatalog {
    public static func entry(for model: MeetingModelID) -> MeetingModelCatalogEntry {
        switch model {
        case .nemotronEnglish1120: nemotronEnglish
        case .whisperLargeV3: whisperLargeV3
        case .nemotron3Fast32: nemotron3Fast32
        case .speakerKit: speakerKit
        }
    }

    public static var entries: [MeetingModelCatalogEntry] {
        MeetingModelID.allCases.map(entry(for:))
    }

    // MARK: Nemotron English, 1120 ms tier (text)

    static let nemotronRepository = "FluidInference/nemotron-speech-streaming-en-0.6b-coreml"
    static let nemotronRevision = "0651794847e50f9687bcaa096c3f8ec696ac6fc4"

    /// Files of `nemotron_coreml_1120ms/`, flat in the model folder. The old
    /// `encoder/` and `preprocessor.mlmodelc` are not loaded and not downloaded.
    private static func nemotron(_ path: String, _ bytes: Int64, _ sha256: String)
        -> MeetingModelFile
    {
        MeetingModelFile(
            repository: nemotronRepository, revision: nemotronRevision,
            remotePath: "nemotron_coreml_1120ms/\(path)", localPath: path, bytes: bytes,
            sha256: sha256)
    }

    /// The v2 encoder (`encoder-v2/1120ms/`), in `encoder/` of the model folder.
    private static func nemotronEncoder(_ path: String, _ bytes: Int64, _ sha256: String)
        -> MeetingModelFile
    {
        let bundle = "encoder_int8_v2.mlmodelc"
        return MeetingModelFile(
            repository: nemotronRepository, revision: nemotronRevision,
            remotePath: "encoder-v2/1120ms/\(bundle)/\(path)",
            localPath: "encoder/\(bundle)/\(path)", bytes: bytes, sha256: sha256)
    }

    static let nemotronEnglish = MeetingModelCatalogEntry(
        id: .nemotronEnglish1120,
        displayName: "Nemotron English",
        licenseName: "NVIDIA Open Model License",
        licenseURL:
            "https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/",
        attribution: "Licensed by NVIDIA Corporation under the NVIDIA Open Model License",
        repository: nemotronRepository,
        revision: nemotronRevision,
        files: [
            nemotron(
                "metadata.json", 441,
                "9489bd276338d193970ff35ccdebe6d2d50e11f936f8e87bac67f46104226095"),
            nemotron(
                "tokenizer.json", 18374,
                "a87b5b8a0e0a989fa7db3121f279ce6af70e337feb55ab553b8d0658db70b9d3"),
            nemotron(
                "decoder.mlmodelc/analytics/coremldata.bin", 243,
                "1e71eacbdeef85ec32ccb31c70670ce73f478fc3427e18c4a17506fcea69b6f6"),
            nemotron(
                "decoder.mlmodelc/coremldata.bin", 493,
                "3fd85d6990627323de4d7970c3c43740d5742e251618afbe8363376827a164a8"),
            nemotron(
                "decoder.mlmodelc/model.mil", 13093,
                "8298f16d3926565b77732b549fa9c64fedebb2e5a29a76e33d0b2e970e93ae69"),
            nemotron(
                "decoder.mlmodelc/weights/weight.bin", 14_429_952,
                "d9758e49f9b2b9a0462c933256663d4174209739e62f0ddc14e4147bc50e7818"),
            nemotron(
                "decoder_joint.mlmodelc/analytics/coremldata.bin", 243,
                "d46ecf790a728d91b8962ec62e597980e288e66c775e45429bf734b54c658ffc"),
            nemotron(
                "decoder_joint.mlmodelc/coremldata.bin", 514,
                "dd0ffdc0887ec882e94710607c82fd26b1f3de66655c03ced1b822e3dc8574c1"),
            nemotron(
                "decoder_joint.mlmodelc/model.mil", 17146,
                "517bb31cf87eb8aa80adaa8c3fee2df0fd7d7dd0c8791e615c5023886c39d572"),
            nemotron(
                "decoder_joint.mlmodelc/weights/weight.bin", 17_876_866,
                "96cac67a1352e45a2418284779dbd5efe5865159b7b92f328247e5ed31485f52"),
            nemotron(
                "joint.mlmodelc/analytics/coremldata.bin", 243,
                "9191ce6547771319e0cefb4bb25c225102d62ffd22035f83bc64c91cae8c6076"),
            nemotron(
                "joint.mlmodelc/coremldata.bin", 401,
                "70798ae506920164d76c1095c0d6227a65965d4288894ce262e0e629356eea0d"),
            nemotron(
                "joint.mlmodelc/model.mil", 5064,
                "73bcc51b58ff73c7620e31a2c32dc5ef4939e8ec2a77ec22242303422bfafba4"),
            nemotron(
                "joint.mlmodelc/weights/weight.bin", 3_446_978,
                "d1d45514a91da39f24e264712a9f8b5a2a90e9cbce04bad3f3f74242bea106d5"),
            nemotronEncoder(
                "analytics/coremldata.bin", 243,
                "bfa033f77995d82743fe196216fa5f9cdb4482f98367d053e94e36d630e0e04a"),
            nemotronEncoder(
                "coremldata.bin", 608,
                "4ddbee0baaa8b705a07e66258b0cb062fbc368e39540416384db57c312b2ad01"),
            nemotronEncoder(
                "model.mil", 986_423,
                "717e23e469ef251f86dd353a5b0af802c0d18ca4a699639e2e090d81c0db1f56"),
            nemotronEncoder(
                "weights/weight.bin", 589_403_200,
                "409df1105de0bed28e68e9d19babcb3885d8edc46bd3640efed64cfd5686f715"),
        ])

    // MARK: WhisperKit large-v3, 626 MB variant (text, final pass only)

    static let whisperRepository = "argmaxinc/whisperkit-coreml"
    static let whisperRevision = "0f63a7800b00dd0226abd051b906c246e1907482"
    static let whisperVariant = "openai_whisper-large-v3-v20240930_626MB"
    static let whisperTokenizerRepository = "openai/whisper-large-v3"
    static let whisperTokenizerRevision = "06f233fe06e710322aca913c1bc4249a0d71fce1"

    private static func whisper(_ path: String, _ bytes: Int64, _ sha256: String)
        -> MeetingModelFile
    {
        MeetingModelFile(
            repository: whisperRepository, revision: whisperRevision,
            remotePath: "\(whisperVariant)/\(path)", localPath: path, bytes: bytes,
            sha256: sha256)
    }

    /// The tokenizer files, directly in the model folder: without them the
    /// WhisperKit load call throws `configurationMissing("tokenizer.json")`.
    private static func whisperTokenizer(_ path: String, _ bytes: Int64, _ sha256: String)
        -> MeetingModelFile
    {
        MeetingModelFile(
            repository: whisperTokenizerRepository, revision: whisperTokenizerRevision,
            remotePath: path, localPath: path, bytes: bytes, sha256: sha256)
    }

    static let whisperLargeV3 = MeetingModelCatalogEntry(
        id: .whisperLargeV3,
        displayName: "WhisperKit large-v3",
        licenseName: "MIT (Core ML model), Apache-2.0 (tokenizer)",
        licenseURL:
            "https://huggingface.co/argmaxinc/whisperkit-coreml/blob/0f63a7800b00dd0226abd051b906c246e1907482/README.md",
        attribution:
            "Whisper large-v3 by OpenAI (Apache-2.0); Core ML conversion by Argmax (MIT)",
        repository: whisperRepository,
        revision: whisperRevision,
        files: [
            whisper(
                "AudioEncoder.mlmodelc/analytics/coremldata.bin", 243,
                "56793886ab1adb9ca8a4e335efbe8af6640f40d958ab2d29c3ad2d7d6f712e95"),
            whisper(
                "AudioEncoder.mlmodelc/coremldata.bin", 348,
                "ffa9eb76e8e9d9be75a4d527e5249e61d67fd43081c5aa110fd24efa6c8c5ea3"),
            whisper(
                "AudioEncoder.mlmodelc/metadata.json", 1922,
                "a87a3375afe79e88e27af30247e234e706b98679dedfd1b021a74f7ee108c669"),
            whisper(
                "AudioEncoder.mlmodelc/model.mil", 934_263,
                "3cec2580fb07b12a88087f0e1586c6ba2982980eb36499561e1ffca2b0950442"),
            whisper(
                "AudioEncoder.mlmodelc/weights/weight.bin", 421_968_768,
                "e4740fa28ed65907af754af893dfce98473fafb84dd8d718ad346985fe7678c1"),
            whisper(
                "MelSpectrogram.mlmodelc/analytics/coremldata.bin", 243,
                "c5be419f8622083ac7046306400643539f0e7577c843448c36defc090d41e7ce"),
            whisper(
                "MelSpectrogram.mlmodelc/coremldata.bin", 329,
                "2bfc12cffc2e45e039c7a18f384f09adffb72c182fcd93f9413d405d1a6c1130"),
            whisper(
                "MelSpectrogram.mlmodelc/metadata.json", 1850,
                "2bc552e09a6f124d9e6c178dd1a6979e010206acb26308b2224887c9dcbeb35f"),
            whisper(
                "MelSpectrogram.mlmodelc/model.mil", 10143,
                "c270b95b5f81d7f7d0b8a3e8f991d4e5812a37cad29349868a35b91f3a6a4463"),
            whisper(
                "MelSpectrogram.mlmodelc/weights/weight.bin", 373_376,
                "009d9fb8f6b589accfa08cebf1c712ef07c3405229ce3cfb3a57ee033c9d8a49"),
            whisper(
                "TextDecoder.mlmodelc/analytics/coremldata.bin", 243,
                "3913b8c9716b284a917cf3744f4d415f2a05e2b910594a14c6cc10092284d3f8"),
            whisper(
                "TextDecoder.mlmodelc/coremldata.bin", 633,
                "3faabaf66930e66956d8291d0ff485fb382496e30a91a7185548b9b898ce90a9"),
            whisper(
                "TextDecoder.mlmodelc/metadata.json", 4924,
                "994f6030d7b1a8be999940444c3cf5d6a57d40ddd4423cf1d1fc93520aa1b052"),
            whisper(
                "TextDecoder.mlmodelc/model.mil", 217_177,
                "dbe833be9e64348c95b7fa598d0ae4309a91aedce4e82fa500a714b0e4b5d754"),
            whisper(
                "TextDecoder.mlmodelc/weights/weight.bin", 203_199_860,
                "d69700903d518ada33170ab77faaaf464496fb9ff65752c6d5a6109aa2fb02db"),
            whisper(
                "config.json", 1149,
                "f01d83dd891791d6f12421c05d3ed8ebbe70866f10d6c9a7a7e80b558ce5a0f1"),
            whisper(
                "generation_config.json", 2767,
                "7fbb053a023be11fbeccd8421811610308143daa93d9617c52aab4a0fa1491c6"),
            whisperTokenizer(
                "tokenizer.json", 2_480_617,
                "6d8cbd7cd0d8d5815e478dac67b85a26bbe77c1f5e0c6d76d1ce2abc0e5f21ca"),
            whisperTokenizer(
                "tokenizer_config.json", 282_843,
                "844b642c73a91359722f47b35705f7174686df33d252695d8572cf9ac03a6389"),
        ])

    // MARK: Nemotron 3 Diarization, fast32 preset (speakers)

    static let diarizationRepository = "FluidInference/nemotron-3-diarization-coreml"
    static let diarizationRevision = "25a90f97f254428d4b30374b76af9c74fdee8327"

    /// The `.mlmodelc` bundle and `learnable_sil_emb.bin` side by side in one
    /// flat folder (the local-path load call needs this layout).
    private static func diarization(_ path: String, _ bytes: Int64, _ sha256: String)
        -> MeetingModelFile
    {
        let bundle = "Nemotron3Diarizer_fast32.mlmodelc"
        return MeetingModelFile(
            repository: diarizationRepository, revision: diarizationRevision,
            remotePath: "monolithic/v2/\(bundle)/\(path)", localPath: "\(bundle)/\(path)",
            bytes: bytes, sha256: sha256)
    }

    static let nemotron3Fast32 = MeetingModelCatalogEntry(
        id: .nemotron3Fast32,
        displayName: "Nemotron 3 speakers",
        licenseName: "OpenMDW License v1.1",
        licenseURL:
            "https://huggingface.co/FluidInference/nemotron-3-diarization-coreml/blob/25a90f97f254428d4b30374b76af9c74fdee8327/README.md",
        attribution:
            "Nemotron 3 Diarization by NVIDIA under the OpenMDW License v1.1; Core ML conversion by Fluid Inference",
        repository: diarizationRepository,
        revision: diarizationRevision,
        files: [
            diarization(
                "analytics/coremldata.bin", 243,
                "7932ba85d07f09ba8feff996e1278f376a9139e31141d2827021f1c225e590ae"),
            diarization(
                "coremldata.bin", 755,
                "fbc2d4dc25147427269e4774a5b8e3dd6b613e8c8458d74c7462a1a377dbae75"),
            diarization(
                "model.mil", 501_830,
                "e2f0cbbf88e824385475779b637c36281c5f98f339783840bdf7b3dfcd08c123"),
            diarization(
                "weights/weight.bin", 198_566_016,
                "7353d8e7a5d29a8d15edf86dbf40bed4e82b7b8f456f302d5cdcbf850ed25358"),
            MeetingModelFile(
                repository: diarizationRepository, revision: diarizationRevision,
                remotePath: "learnable_sil_emb.bin", localPath: "learnable_sil_emb.bin",
                bytes: 2048,
                sha256: "d4417b3c0eabdf7c47032fac2b5b5a7ee83d819a6ddda8fd8eaf74e2b5cc4ac7"),
        ])

    // MARK: SpeakerKit (pyannote), default variant (speakers)

    static let speakerKitRepository = "argmaxinc/speakerkit-coreml"
    static let speakerKitRevision = "556fc52a13327837688f02289457cded017802e9"

    /// The same nested tree as the repository: segmenter `W8A16`, embedder
    /// `W8A16`, clusterer `W32A32` (the variant the default configuration selects).
    private static func speakerKit(
        _ bundle: String, _ path: String, _ bytes: Int64, _ sha256: String
    ) -> MeetingModelFile {
        MeetingModelFile(
            repository: speakerKitRepository, revision: speakerKitRevision,
            remotePath: "\(bundle)/\(path)", localPath: "\(bundle)/\(path)", bytes: bytes,
            sha256: sha256)
    }

    private static let segmenter = "speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter.mlmodelc"
    private static let embedder = "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder.mlmodelc"
    private static let embedderPreprocessor =
        "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedderPreprocessor.mlmodelc"
    private static let clusterer = "speaker_clusterer/pyannote-v4/W32A32/PldaProjector.mlmodelc"

    static let speakerKit = MeetingModelCatalogEntry(
        id: .speakerKit,
        displayName: "SpeakerKit speakers",
        licenseName: "CC BY 4.0",
        licenseURL:
            "https://huggingface.co/argmaxinc/speakerkit-coreml/blob/556fc52a13327837688f02289457cded017802e9/README.md",
        attribution: "pyannote speaker models, Core ML conversion by Argmax, under CC BY 4.0",
        repository: speakerKitRepository,
        revision: speakerKitRevision,
        files: [
            speakerKit(
                segmenter, "analytics/coremldata.bin", 243,
                "40637aa0cb2a073bc303c7ca9ee79da35fa81d2cad1ead180e93b134005b95de"),
            speakerKit(
                segmenter, "coremldata.bin", 497,
                "6c356ed983b2a3332ce51299ca0f9747a35cb6c2a67b0ac24c69dbef3f989634"),
            speakerKit(
                segmenter, "metadata.json", 3757,
                "2fd6aaf6beb17b3758f5d0c5b2cf5feeacb0cc0c9267dbcd7536b247b1a5860e"),
            speakerKit(
                segmenter, "model.mil", 193_092,
                "423c358915acab0d440c99f5162c17456936c2c02f7394b05ab226b9a34c122a"),
            speakerKit(
                segmenter, "weights/weight.bin", 1_520_986,
                "75ff1725ef4e58dacf9176466ec274a8a13a6132c296d6b571fb78ddad5455c4"),
            speakerKit(
                embedder, "analytics/coremldata.bin", 243,
                "ba8405dfc9b9348ade705e052888b4bdc7fb8d079ef3ff71108a5f692d0209f2"),
            speakerKit(
                embedder, "coremldata.bin", 370,
                "1597d6c037ac52436b5c2e1abc47e6c68483c19eeac75267dfb8795a78ec07c5"),
            speakerKit(
                embedder, "metadata.json", 2367,
                "29ea3421161c8344f6ea95db9b472217638a869f686f2494d10e5d11f11f4cda"),
            speakerKit(
                embedder, "model.mil", 451_487,
                "5eee9f6aa380aef88fee604d75c5deaa23adc83c9480cb8f6dedc72803973e77"),
            speakerKit(
                embedder, "weights/weight.bin", 6_661_888,
                "a02861969f47cf3a67e3b0d276e54b3c8bc3a6e43d40d77d1cccbd57da0e5795"),
            speakerKit(
                embedderPreprocessor, "analytics/coremldata.bin", 243,
                "ce9bef9fb3125a5401300b5c5998c5d8f211094692cae780645d3e2757410f2c"),
            speakerKit(
                embedderPreprocessor, "coremldata.bin", 330,
                "b4ebd0b9ce5a84768672663aff426eb19f9648d4b9f74286f0e19fc753ad76ba"),
            speakerKit(
                embedderPreprocessor, "metadata.json", 1979,
                "789f81c17dc04d469611d253684e534565fb4a008e54c722b925f1608bf87fce"),
            speakerKit(
                embedderPreprocessor, "model.mil", 14224,
                "42e552ebd7efb12ea813eceb474018dd0f46168e84ad3a1c54945bfc47be7a82"),
            speakerKit(
                embedderPreprocessor, "weights/weight.bin", 2_181_696,
                "5f2c284bd22f1f7ab76901c1c6e57f82d4ebbf057fa0b924aad057f124f77a89"),
            speakerKit(
                clusterer, "analytics/coremldata.bin", 243,
                "3e13c8f4df77ea27cbbcdd6d083c63f5e7b3f32566cc5bf223fab92d40b81b8b"),
            speakerKit(
                clusterer, "coremldata.bin", 327,
                "6f6820ccf221d4cc7c107101d0ae4d716eb224e4fdffaf8f7ca36af70ae64c40"),
            speakerKit(
                clusterer, "metadata.json", 1766,
                "acc86b4a4f542d8e7eaf84fc290fe72bd8629b0ffcc16e5b1a9e13d777abd9d8"),
            speakerKit(
                clusterer, "model.mil", 8128,
                "209e641bf4d9c3868c9dc43ab8705094997917eb2df5f5d8c8fda09fed54b1d4"),
            speakerKit(
                clusterer, "weights/weight.bin", 199_040,
                "a1dbbb651a0a67fcfe5334672f459df090fa960917a6ee3a5423245a7ab92ced"),
        ])
}
