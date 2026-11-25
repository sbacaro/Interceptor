import SwiftUI

/// Subtle native macOS in-app banner notifying the user when a newer GitHub release is available.
struct UpdateBannerView: View {
    let updater: GitHubReleaseUpdater
    let onInstall: (AvailableUpdate) -> Void

    @State private var isNotesPresented = false

    var body: some View {
        switch updater.state {
        case let .updateAvailable(update):
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color("AccentColor"))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Interceptor \(update.version.description) is available")
                        .font(.callout.weight(.semibold))
                    Text("You are running \(updater.currentVersionString). Download and install directly from GitHub Releases.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                if !update.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Notes") {
                        isNotesPresented.toggle()
                    }
                    .controlSize(.small)
                    .popover(isPresented: $isNotesPresented, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(update.title)
                                    .font(.headline)
                                Spacer(minLength: 8)
                                if let htmlURL = update.htmlURL {
                                    Link("GitHub", destination: htmlURL)
                                        .font(.caption)
                                }
                            }

                            Divider()

                            ScrollView {
                                ReleaseNotesMarkdownView(markdown: update.releaseNotes)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .padding(.trailing, 8)
                            }
                            .frame(maxHeight: 300)
                        }
                        .padding(16)
                        .frame(width: 420)
                    }
                }

                Button("Install Update") {
                    onInstall(update)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    updater.isBannerDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss until next launch")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color("AccentColor").opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color("AccentColor").opacity(0.25), lineWidth: 1)
            )

        case let .downloading(progress):
            HStack(spacing: 12) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 180)

                Text("Downloading update… \(Int(progress * 100))%")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.10))
            )

        case .installing:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Verifying and installing update…")
                    .font(.callout.weight(.medium))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.10))
            )

        default:
            EmptyView()
        }
    }
}

/// Lightweight native SwiftUI renderer for GitHub Release Notes Markdown
/// (headings, bullet/numbered lists, horizontal dividers, fenced code blocks, and inline formatting).
private struct ReleaseNotesMarkdownView: View {
    private enum Block: Identifiable {
        case heading(id: Int, level: Int, text: String)
        case bullet(id: Int, indent: Int, marker: String, text: String)
        case paragraph(id: Int, text: String)
        case codeBlock(id: Int, code: String)
        case divider(id: Int)

        var id: Int {
            switch self {
            case let .heading(id, _, _),
                 let .bullet(id, _, _, _),
                 let .paragraph(id, _),
                 let .codeBlock(id, _),
                 let .divider(id):
                return id
            }
        }
    }

    let markdown: String

    private var blocks: [Block] {
        Self.parseBlocks(from: markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                switch block {
                case let .heading(_, level, text):
                    Text(Self.inlineMarkdown(text))
                        .font(level <= 2 ? .subheadline.weight(.semibold) : .caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.top, index == 0 ? 0 : 6)

                case let .bullet(_, indent, marker, text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(Self.inlineMarkdown(text))
                            .font(.caption)
                            .foregroundStyle(.primary.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(min(indent, 2)) * 12)

                case let .paragraph(_, text):
                    Text(Self.inlineMarkdown(text))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                case let .codeBlock(_, code):
                    Text(code)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.primary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )

                case .divider:
                    Divider()
                        .padding(.vertical, 4)
                }
            }
        }
    }

    private static func inlineMarkdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private static func parseBlocks(from raw: String) -> [Block] {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var result: [Block] = []
        var nextID = 0
        var inCodeBlock = false
        var codeLines: [String] = []
        var paragraphLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let joined = paragraphLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty {
                result.append(.paragraph(id: nextID, text: joined))
                nextID += 1
            }
            paragraphLines.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                if inCodeBlock {
                    result.append(.codeBlock(id: nextID, code: codeLines.joined(separator: "\n")))
                    nextID += 1
                    codeLines.removeAll()
                    inCodeBlock = false
                } else {
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if isHorizontalRule(trimmed) {
                flushParagraph()
                result.append(.divider(id: nextID))
                nextID += 1
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushParagraph()
                result.append(.heading(id: nextID, level: heading.level, text: heading.text))
                nextID += 1
                continue
            }

            if let bullet = parseListItem(line) {
                flushParagraph()
                result.append(.bullet(id: nextID, indent: bullet.indent, marker: bullet.marker, text: bullet.text))
                nextID += 1
                continue
            }

            paragraphLines.append(trimmed)
        }

        flushParagraph()
        if inCodeBlock && !codeLines.isEmpty {
            result.append(.codeBlock(id: nextID, code: codeLines.joined(separator: "\n")))
        }

        return result
    }

    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        let stripped = trimmed.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" } ||
            stripped.allSatisfy { $0 == "*" } ||
            stripped.allSatisfy { $0 == "_" }
    }

    private static func parseHeading(_ trimmed: String) -> (level: Int, text: String)? {
        var level = 0
        for ch in trimmed {
            if ch == "#" {
                level += 1
            } else {
                break
            }
        }
        guard (1...6).contains(level) else { return nil }
        let afterHashes = trimmed.dropFirst(level)
        guard afterHashes.first == " " else { return nil }
        let text = afterHashes.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (level, text)
    }

    private static func parseListItem(_ rawLine: String) -> (indent: Int, marker: String, text: String)? {
        let leadingSpaces = rawLine.prefix(while: { $0 == " " || $0 == "\t" })
            .reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
        let rest = rawLine.drop(while: { $0 == " " || $0 == "\t" })

        if rest.hasPrefix("- ") || rest.hasPrefix("* ") || rest.hasPrefix("+ ") {
            let text = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            let indent = leadingSpaces / 2
            return (indent, indent == 0 ? "•" : "◦", text)
        }

        // Numbered list item like "1. Item"
        let digits = rest.prefix(while: \.isNumber)
        if !digits.isEmpty {
            let afterDigits = rest.dropFirst(digits.count)
            if afterDigits.hasPrefix(". ") {
                let text = afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return nil }
                return (leadingSpaces / 2, "\(digits).", text)
            }
        }

        return nil
    }
}
