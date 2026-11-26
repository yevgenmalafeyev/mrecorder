import AppKit
import AVFoundation
import Foundation

/// Runs after each recording, in the background, one recording at a time:
/// transcribe (mlx_whisper) → subtitles (.srt + embedded track via ffmpeg) →
/// summary and title (claude CLI) → rename files with the title.
actor PostProcessor {
    static let shared = PostProcessor()

    static let whisperModel = "mlx-community/whisper-large-v3-turbo"

    /// Status for the menu ("Transcribing…"); nil when idle. Called on the main queue.
    nonisolated(unsafe) var onStatus: ((String?) -> Void)?
    /// Called on the main queue with the final video URL (it may have been renamed).
    nonisolated(unsafe) var onFinished: ((URL) -> Void)?

    struct Options {
        var normalize: Bool
        var transcribe: Bool
        var embedSubtitles: Bool
        var summary: Bool
        var sections: (short: Bool, actions: Bool, chapters: Bool, transcript: Bool)
        var claudeNaming: Bool

        static func current() -> Options {
            Options(
                normalize: Settings.normalizeAudio,
                transcribe: Settings.transcribe,
                embedSubtitles: Settings.embedSubtitles,
                summary: Settings.summaryEnabled && Settings.transcribe,
                sections: (Settings.summaryShort, Settings.summaryActions, Settings.summaryChapters, Settings.summaryTranscript),
                claudeNaming: Settings.namingMode == .claude
            )
        }

        var needsWork: Bool { normalize || transcribe || summary || claudeNaming }
    }

    struct Segment { let start: Double; let end: Double; let text: String }

    /// `videos`: the files of one recording, main file first (several when screens are recorded separately).
    /// `baseName`: shared name prefix, e.g. "2026-11-25 001"; .srt and .md files use it.
    func process(_ videos: [URL], baseName: String, options: Options) async {
        guard let main = videos.first else { return }
        guard options.needsWork else {
            await MainActor.run { onFinished?(main) }
            return
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macrecorder-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let video = main
        let base = main.deletingLastPathComponent().appendingPathComponent(baseName)
        var segments: [Segment] = []
        var language = ""

        // 0. Level the audio first, so transcription hears the levelled mix too.
        if options.normalize {
            status("Levelling audio…")
            await normalize(videos)
        }

        // 1. Transcribe
        if options.transcribe {
            if let whisper = Tools.whisper {
                status("Transcribing…")
                do {
                    (segments, language) = try await transcribe(video, whisper: whisper, tmp: tmp)
                    let srt = tmp.appendingPathComponent("t.srt")
                    let speech = segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                    if speech.count > 3, FileManager.default.fileExists(atPath: srt.path) {
                        let dest = base.appendingPathExtension("srt")
                        try? FileManager.default.removeItem(at: dest)
                        try FileManager.default.copyItem(at: srt, to: dest)
                        // 2. Embed subtitles
                        if options.embedSubtitles, let ffmpeg = Tools.ffmpeg {
                            status("Adding subtitles…")
                            for v in videos {
                                try await embed(srt: dest, into: v, language: language, ffmpeg: ffmpeg, tmp: tmp)
                            }
                        }
                    } else {
                        segments = []
                        log.info("No speech detected; skipping subtitles")
                    }
                } catch {
                    log.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                log.error("mlx_whisper not found; skipping transcription")
            }
        }

        // 3. Summary and title
        var title: String?
        if options.summary || options.claudeNaming {
            if let claude = Tools.claude {
                status(options.summary ? "Summarizing…" : "Naming…")
                do {
                    let (t, md) = try await askClaude(
                        claude: claude, video: video, segments: segments, options: options, tmp: tmp
                    )
                    title = options.claudeNaming ? t : nil
                    if options.summary {
                        try writeSummary(md: md, title: t, segments: segments, options: options, base: base)
                    }
                } catch {
                    log.error("Claude step failed: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                log.error("claude CLI not found; skipping summary and naming")
            }
            if options.summary, !FileManager.default.fileExists(atPath: base.appendingPathExtension("md").path),
               !segments.isEmpty, options.sections.transcript {
                // No Claude: still save the transcript.
                try? writeSummary(md: "", title: nil, segments: segments, options: options, base: base)
            }
        }

        // 4. Rename with the title
        var final = main
        if let title {
            let files = videos + [base.appendingPathExtension("srt"), base.appendingPathExtension("md")]
            // (videos may be .mp4 or .mov)
            let renamed = rename(files, baseName: baseName, title: title)
            final = renamed[main] ?? main
        }

        status(nil)
        let result = final
        await MainActor.run { onFinished?(result) }
    }

    private func status(_ text: String?) {
        let cb = onStatus
        DispatchQueue.main.async { cb?(text) }
    }

    // MARK: - Loudness

    /// Measures the main file once; every file of the recording has the same audio, so the same gains apply.
    private func normalize(_ videos: [URL]) async {
        guard let main = videos.first else { return }
        do {
            let started = Date()
            let (plan, a) = try await AudioNormalizer.analyze(main)
            func lufs(_ v: Double?) -> String { v.map { String(format: "%.1f LUFS", $0) } ?? "silent" }
            func db(_ g: Float) -> String { String(format: "%+.1f dB", 20 * log10(Double(g))) }
            let mixAfter = a.mixLoudness(systemGain: Double(plan.systemGain * plan.mixGain),
                                         micGain: Double(plan.micGain * plan.mixGain))
            let summary = "system \(lufs(a.systemLoudness)), mic \(lufs(a.micLoudness)); gains system \(db(plan.systemGain)), mic \(db(plan.micGain)), mix \(db(plan.mixGain)); mix now \(lufs(mixAfter))"
            log.notice("Loudness: \(summary, privacy: .public)")
            if !plan.isIdentity {
                for v in videos { try await AudioNormalizer.apply(plan, to: v) }
            }
            log.notice("Audio levelled in \(String(format: "%.1f", Date().timeIntervalSince(started)), privacy: .public) s")
        } catch {
            log.error("Audio levelling failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Transcription

    private func transcribe(_ video: URL, whisper: URL, tmp: URL) async throws -> ([Segment], String) {
        let r = try await Tools.run(whisper, [
            video.path,
            "--model", Self.whisperModel,
            "--output-dir", tmp.path,
            "--output-name", "t",
            "--output-format", "all",
            "--verbose", "False",
            "--condition-on-previous-text", "False",
        ], cwd: tmp, timeout: 4 * 3600)
        guard r.ok else { throw ToolError.failed("mlx_whisper", r.stderr.suffix(500).description) }

        let data = try Data(contentsOf: tmp.appendingPathComponent("t.json"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let language = json["language"] as? String ?? ""
        let segments = (json["segments"] as? [[String: Any]] ?? []).compactMap { s -> Segment? in
            guard let start = s["start"] as? Double, let end = s["end"] as? Double,
                  let text = s["text"] as? String else { return nil }
            return Segment(start: start, end: end, text: text.trimmingCharacters(in: .whitespaces))
        }
        log.info("Transcribed \(segments.count) segments, language \(language, privacy: .public)")
        return (segments, language)
    }

    private func embed(srt: URL, into video: URL, language: String, ffmpeg: URL, tmp: URL) async throws {
        let out = tmp.appendingPathComponent("embedded." + video.pathExtension)
        let lang = Self.iso639_2[language] ?? "und"
        let r = try await Tools.run(ffmpeg, [
            "-y", "-v", "error",
            "-i", video.path, "-i", srt.path,
            "-map", "0", "-map", "1",
            "-c", "copy", "-c:s", "mov_text",
            "-metadata:s:s:0", "language=\(lang)",
            "-disposition:a:0", "default",
            "-disposition:a:1", "0", "-disposition:a:2", "0",
            "-disposition:s:0", "0",
            out.path,
        ], timeout: 3600)
        guard r.ok else { throw ToolError.failed("ffmpeg", r.stderr.suffix(500).description) }
        _ = try FileManager.default.replaceItemAt(video, withItemAt: out)
    }

    static let iso639_2: [String: String] = [
        "en": "eng", "uk": "ukr", "ru": "rus", "de": "deu", "pt": "por", "pl": "pol",
        "es": "spa", "fr": "fra", "it": "ita", "nl": "nld", "cs": "ces", "tr": "tur",
    ]

    // MARK: - Claude

    private func askClaude(claude: URL, video: URL, segments: [Segment], options: Options,
                           tmp: URL) async throws -> (title: String, markdown: String) {
        let duration = try await AVURLAsset(url: video).load(.duration).seconds
        var prompt = """
        You are processing a screen recording (duration \(Self.timestamp(duration))).

        """
        var args = ["-p", "--model", "sonnet"]

        if segments.isEmpty {
            // No speech: name from a few screenshots instead.
            let frames = try await extractFrames(video, duration: duration, tmp: tmp)
            prompt += """
            There is no speech. Use the Read tool to view these screenshots taken from the recording:
            \(frames.map(\.path).joined(separator: "\n"))

            """
            args += ["--allowedTools", "Read"]
        } else {
            prompt += """
            Transcript (timestamps are [mm:ss] from the start):
            <transcript>
            \(Self.transcriptText(segments))
            </transcript>

            """
        }

        prompt += """

        Write in the main language of the transcript (or English if there is none).
        Output exactly this format and nothing else:
        TITLE: <a short descriptive file title, max 8 words, no date, no quotes, no punctuation at the end>
        ---
        """
        if options.summary && !segments.isEmpty {
            var sections: [String] = []
            if options.sections.short { sections.append("## Summary\nA few short paragraphs about what was discussed or shown.") }
            if options.sections.actions {
                sections.append("## Decisions and action items\nBullet list: decisions made; action items with owner if known. Write \"None\" if there are none.")
            }
            if options.sections.chapters {
                sections.append("## Chapters\nBullet list of topics with their start time, formatted \"- [mm:ss] Topic\".")
            }
            prompt += "\n" + (sections.isEmpty ? "(nothing after the --- line)" : sections.joined(separator: "\n\n"))
        } else {
            prompt += "\n(nothing after the --- line)"
        }

        let r = try await Tools.run(claude, args, stdin: prompt, cwd: tmp, timeout: 600)
        guard r.ok else { throw ToolError.failed("claude", (r.stderr + r.stdout).suffix(500).description) }

        let text = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        var title = ""
        var markdown = ""
        if let titleLine = text.components(separatedBy: .newlines).first(where: { $0.hasPrefix("TITLE:") }) {
            title = String(titleLine.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
        if let range = text.range(of: "\n---") {
            markdown = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if markdown.hasPrefix("(nothing") { markdown = "" }
        }
        guard !title.isEmpty else { throw ToolError.failed("claude", "no title in output") }
        return (title, markdown)
    }

    private func extractFrames(_ video: URL, duration: Double, tmp: URL) async throws -> [URL] {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        gen.maximumSize = CGSize(width: 1600, height: 1600)
        gen.appliesPreferredTrackTransform = true
        var urls: [URL] = []
        for (i, f) in [0.15, 0.5, 0.85].enumerated() {
            let t = CMTime(seconds: duration * f, preferredTimescale: 600)
            let (image, _) = try await gen.image(at: t)
            let url = tmp.appendingPathComponent("frame\(i).png")
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            urls.append(url)
        }
        return urls
    }

    // MARK: - Files

    private func writeSummary(md: String, title: String?, segments: [Segment], options: Options, base: URL) throws {
        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .short
        let created = Date()
        var out = "# \(title ?? base.lastPathComponent)\n\n"
        out += "_Recorded \(df.string(from: created))_\n\n"
        if !md.isEmpty { out += md + "\n\n" }
        if options.sections.transcript, !segments.isEmpty {
            out += "## Transcript\n\n" + Self.transcriptText(segments) + "\n"
        }
        try out.write(to: base.appendingPathExtension("md"), atomically: true, encoding: .utf8)
    }

    /// Inserts the title after the base name in every file name:
    /// "2026-11-25 001 (LG).mp4" -> "2026-11-25 001 Weekly sync (LG).mp4". Returns old -> new URLs.
    private func rename(_ files: [URL], baseName: String, title: String) -> [URL: URL] {
        let clean = title
            .replacingOccurrences(of: "[/:\\\\\"*?<>|\\n\\r]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        guard !clean.isEmpty else { return [:] }
        let short = String(clean.prefix(80))
        var result: [URL: URL] = [:]
        for from in files where FileManager.default.fileExists(atPath: from.path) {
            let name = from.lastPathComponent
            guard name.hasPrefix(baseName) else { continue }
            let to = from.deletingLastPathComponent()
                .appendingPathComponent(baseName + " " + short + name.dropFirst(baseName.count))
            guard !FileManager.default.fileExists(atPath: to.path) else { continue }
            do {
                try FileManager.default.moveItem(at: from, to: to)
                result[from] = to
            } catch {
                log.error("Rename failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return result
    }

    static func transcriptText(_ segments: [Segment]) -> String {
        segments.map { "[\(timestamp($0.start))] \($0.text)" }.joined(separator: "\n")
    }

    static func timestamp(_ s: Double) -> String {
        let t = Int(max(0, s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
                         : String(format: "%02d:%02d", t / 60, t % 60)
    }
}

enum ToolError: LocalizedError {
    case failed(String, String)
    var errorDescription: String? {
        if case .failed(let tool, let detail) = self { return "\(tool) failed: \(detail)" }
        return nil
    }
}
