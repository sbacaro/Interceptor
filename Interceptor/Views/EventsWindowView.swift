import AppKit
import InterceptorEngine
import SwiftUI
import UniformTypeIdentifiers

/// Dedicated Dante Controller-inspired diagnostic Events window (`⌘E`) showing chronological
/// session events, severity/source/text filters, copy/export actions, and live monitoring status.
struct EventsWindowView: View {
    @Bindable var viewModel: AppViewModel
    let appDelegate: AppDelegate

    @Environment(\.openWindow) private var openWindow

    @State private var severityFilter: SeverityFilter = .all
    @State private var sourceFilter: SourceFilter = .all
    @State private var searchText: String = ""
    @State private var selection: Set<EngineEvent.ID> = []
    @State private var didCopyRecently: Bool = false
    @State private var copyFeedbackTask: Task<Void, Never>?

    private enum SeverityFilter: String, CaseIterable, Identifiable {
        case all
        case errors
        case warnings
        case info

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .all: "All"
            case .errors: "Errors"
            case .warnings: "Warnings"
            case .info: "Info"
            }
        }

        func matches(_ severity: EventSeverity) -> Bool {
            switch self {
            case .all: true
            case .errors: severity == .error
            case .warnings: severity == .warning
            case .info: severity == .info
            }
        }
    }

    private enum SourceFilter: Hashable, Identifiable {
        case all
        case bridge(UUID)
        case named(String)

        var id: String {
            switch self {
            case .all: "all"
            case let .bridge(uuid): "bridge:\(uuid.uuidString)"
            case let .named(name): "named:\(name)"
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static let exportFilenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    var body: some View {
        let entries = viewModel.engine.eventLog.entries
        let scopeFiltered = entriesFilteredBySourceAndSearch(from: entries)
        let filteredEvents = scopeFiltered.filter { severityFilter.matches($0.severity) }

        VStack(spacing: 0) {
            filterBar(scopeEntries: scopeFiltered)

            Divider()

            if filteredEvents.isEmpty {
                emptyStateView(hasAnyEvents: !entries.isEmpty)
            } else {
                eventsTable(events: filteredEvents)
            }

            Divider()

            footerStatusStrip(allEntries: entries, filteredCount: filteredEvents.count)
        }
        .frame(minWidth: 660, minHeight: 340)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                let copyTitle: LocalizedStringKey = didCopyRecently ? "Copied" : "Copy"
                Button {
                    copyFilteredEvents(filteredEvents)
                } label: {
                    Label(copyTitle, systemImage: didCopyRecently ? "checkmark" : "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(filteredEvents.isEmpty)
                .help("Copy visible events to clipboard")

                Button {
                    exportFilteredEvents(filteredEvents)
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(filteredEvents.isEmpty)
                .help("Export visible events to a .log file")
            }

            ToolbarSpacer(.fixed)

            ToolbarItem(placement: .automatic) {
                Button {
                    clearEvents()
                } label: {
                    Label("Clear", systemImage: "trash")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(entries.isEmpty)
                .help("Clear all recorded session events")
            }
        }
        .background(
            EventsWindowRegistrationView { window in
                appDelegate.registerEventsWindow(window)
            }
        )
        .onAppear {
            appDelegate.viewModel = viewModel
            appDelegate.openEventsWindowAction = { openWindow(id: "events") }
            viewModel.engine.eventLog.isEventsWindowVisible = true
        }
        .onDisappear {
            copyFeedbackTask?.cancel()
            copyFeedbackTask = nil
            viewModel.engine.eventLog.isEventsWindowVisible = false
        }
        .onChange(of: availableSourceFilterIDs) { _, validIDs in
            if !validIDs.contains(sourceFilter.id) {
                sourceFilter = .all
            }
        }
    }

    // MARK: - Top Filter Bar

    private func filterBar(scopeEntries: [EngineEvent]) -> some View {
        let errorCount = scopeEntries.count { $0.severity == .error }
        let warningCount = scopeEntries.count { $0.severity == .warning }
        let infoCount = scopeEntries.count { $0.severity == .info }

        return HStack(spacing: 10) {
            HStack(spacing: 4) {
                SeverityFilterPill(
                    title: SeverityFilter.all.title,
                    count: scopeEntries.count,
                    badgeColor: .secondary,
                    useSolidBadge: false,
                    isSelected: severityFilter == .all
                ) {
                    severityFilter = .all
                }

                SeverityFilterPill(
                    title: SeverityFilter.errors.title,
                    count: errorCount,
                    badgeColor: .red,
                    useSolidBadge: true,
                    isSelected: severityFilter == .errors
                ) {
                    severityFilter = .errors
                }

                SeverityFilterPill(
                    title: SeverityFilter.warnings.title,
                    count: warningCount,
                    badgeColor: .orange,
                    useSolidBadge: true,
                    isSelected: severityFilter == .warnings
                ) {
                    severityFilter = .warnings
                }

                SeverityFilterPill(
                    title: SeverityFilter.info.title,
                    count: infoCount,
                    badgeColor: .secondary,
                    useSolidBadge: false,
                    isSelected: severityFilter == .info
                ) {
                    severityFilter = .info
                }
            }
            .fixedSize()

            Spacer(minLength: 8)

            Picker("Source", selection: $sourceFilter) {
                Text("All Sources").tag(SourceFilter.all)

                let bridges = viewModel.engine.bridges
                if !bridges.isEmpty {
                    Divider()
                    ForEach(bridges) { bridge in
                        Text(bridge.name).tag(SourceFilter.bridge(bridge.id))
                    }
                }

                let extraSources = additionalSourceNames
                if !extraSources.isEmpty {
                    Divider()
                    ForEach(extraSources, id: \.self) { name in
                        Text(name).tag(SourceFilter.named(name))
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 120, maxWidth: 170)
            .help("Filter events by source")

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                TextField("Search events…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Clear search"))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minWidth: 150, idealWidth: 185, maxWidth: 210)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.75)
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Diagnostic Table & Empty State

    private func eventsTable(events: [EngineEvent]) -> some View {
        Table(events, selection: $selection) {
            TableColumn("Time") { event in
                Text(Self.timeFormatter.string(from: event.timestamp))
                    .font(.system(.caption, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 92, ideal: 96, max: 112)

            TableColumn("Type") { event in
                Image(systemName: severitySymbolName(for: event.severity))
                    .font(.callout)
                    .foregroundStyle(severityColor(for: event.severity))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .help(event.severity.displayName)
                    .accessibilityLabel(Text(event.severity.displayName))
            }
            .width(44)

            TableColumn("Source") { event in
                Text(event.sourceName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(event.sourceName)
            }
            .width(min: 100, ideal: 140, max: 240)

            TableColumn("Message") { event in
                Text(event.message)
                    .font(.callout)
                    .lineLimit(2)
                    .help(event.message)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: EngineEvent.ID.self) { selectedIDs in
            let targets = events.filter { selectedIDs.contains($0.id) }
            if !targets.isEmpty {
                Button(targets.count == 1 ? "Copy Event Line" : "Copy Selected Events") {
                    copyToPasteboard(EventLog.exportText(for: targets))
                }
                if targets.count == 1, let single = targets.first {
                    Button("Copy Message") {
                        copyToPasteboard(single.message)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func emptyStateView(hasAnyEvents: Bool) -> some View {
        if hasAnyEvents {
            ContentUnavailableView {
                Label("No Matching Events", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("No events match the current severity, source, or search filter.")
            } actions: {
                Button("Reset Filters") {
                    severityFilter = .all
                    sourceFilter = .all
                    searchText = ""
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("No Events Recorded", systemImage: "list.bullet.rectangle")
            } description: {
                Text("Diagnostic events for bridges, interfaces, clock sync, and updates will appear here during your session.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Footer Status Strip

    private func footerStatusStrip(allEntries: [EngineEvent], filteredCount: Int) -> some View {
        let errorCount = allEntries.count { $0.severity == .error }
        let warningCount = allEntries.count { $0.severity == .warning }

        return HStack(spacing: 8) {
            HStack(spacing: 6) {
                if filteredCount != allEntries.count {
                    Text("\(filteredCount) of \(allEntries.count) events")
                } else if allEntries.count == 1 {
                    Text("1 event")
                } else {
                    Text("\(allEntries.count) events")
                }

                Text("·")
                    .foregroundStyle(.tertiary)

                Group {
                    if errorCount == 1 {
                        Text("1 error")
                    } else {
                        Text("\(errorCount) errors")
                    }
                }
                .foregroundStyle(errorCount > 0 ? Color.red : Color.secondary)

                Text("·")
                    .foregroundStyle(.tertiary)

                Group {
                    if warningCount == 1 {
                        Text("1 warning")
                    } else {
                        Text("\(warningCount) warnings")
                    }
                }
                .foregroundStyle(warningCount > 0 ? Color.orange : Color.secondary)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            Spacer()

            if viewModel.engine.anyBridgeRunning {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("Live · Monitoring active bridges")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.secondary.opacity(0.45))
                        .frame(width: 6, height: 6)
                    Text("Standby")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    // MARK: - Filtering & Source Enumeration

    private var additionalSourceNames: [String] {
        let configuredBridgeIDs = Set(viewModel.engine.bridges.map(\.id))
        var seen: Set<String> = []
        var names: [String] = []
        for event in viewModel.engine.eventLog.entries {
            let isConfiguredBridge = event.bridgeID.map { configuredBridgeIDs.contains($0) } ?? false
            guard !isConfiguredBridge else { continue }
            let name = event.sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            names.append(name)
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var availableSourceFilterIDs: Set<String> {
        var ids: Set<String> = [SourceFilter.all.id]
        for bridge in viewModel.engine.bridges {
            ids.insert(SourceFilter.bridge(bridge.id).id)
        }
        for name in additionalSourceNames {
            ids.insert(SourceFilter.named(name).id)
        }
        return ids
    }

    private func entriesFilteredBySourceAndSearch(from entries: [EngineEvent]) -> [EngineEvent] {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { event in
            let matchesSource: Bool
            switch sourceFilter {
            case .all:
                matchesSource = true
            case let .bridge(bridgeID):
                if let eventBridgeID = event.bridgeID {
                    matchesSource = eventBridgeID == bridgeID
                } else if let bridgeName = viewModel.engine.bridge(for: bridgeID)?.name {
                    matchesSource = event.sourceName == bridgeName
                } else {
                    matchesSource = false
                }
            case let .named(name):
                matchesSource = event.sourceName == name
            }

            guard matchesSource else { return false }
            guard !trimmedQuery.isEmpty else { return true }

            return event.message.localizedCaseInsensitiveContains(trimmedQuery) ||
                event.sourceName.localizedCaseInsensitiveContains(trimmedQuery) ||
                event.category.displayName.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    // MARK: - Actions

    private func copyFilteredEvents(_ events: [EngineEvent]) {
        let text = EventLog.exportText(for: events)
        guard !text.isEmpty else { return }
        copyToPasteboard(text)

        copyFeedbackTask?.cancel()
        didCopyRecently = true
        copyFeedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            didCopyRecently = false
        }
    }

    private func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func exportFilteredEvents(_ events: [EngineEvent]) {
        let text = EventLog.exportText(for: events)
        guard !text.isEmpty else { return }

        let panel = NSSavePanel()
        panel.title = String(localized: "Export Events")
        panel.nameFieldStringValue = Self.defaultExportFilename()
        panel.allowedContentTypes = [.log]
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let writeExport: @MainActor (URL) -> Void = { url in
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }

        if let window = appDelegate.activeEventsWindow ?? NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                Task { @MainActor in
                    writeExport(url)
                }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            writeExport(url)
        }
    }

    private func clearEvents() {
        selection.removeAll()
        sourceFilter = .all
        viewModel.engine.eventLog.clear()
    }

    private static func defaultExportFilename(date: Date = Date()) -> String {
        "Interceptor-Events-\(exportFilenameFormatter.string(from: date)).log"
    }

    // MARK: - Severity Styling

    private func severitySymbolName(for severity: EventSeverity) -> String {
        switch severity {
        case .error: "xmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        }
    }

    private func severityColor(for severity: EventSeverity) -> Color {
        switch severity {
        case .error: .red
        case .warning: .orange
        case .info: .secondary
        }
    }
}

private struct SeverityFilterPill: View {
    let title: LocalizedStringKey
    let count: Int
    let badgeColor: Color
    let useSolidBadge: Bool
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)

                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(useSolidBadge ? .white : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(useSolidBadge ? badgeColor : Color.primary.opacity(0.08))
                        )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.10) : (isHovering ? Color.primary.opacity(0.05) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? Color.primary.opacity(0.14) : Color.clear, lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Captures the hosting `NSWindow` for `EventsWindowView` so `AppDelegate` observes
/// close, miniaturize, occlusion, and focus events specifically for the Events window.
private struct EventsWindowRegistrationView: NSViewRepresentable {
    let onWindowAvailable: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> EventsWindowObserverNSView {
        let view = EventsWindowObserverNSView()
        view.onWindowAvailable = onWindowAvailable
        return view
    }

    func updateNSView(_ nsView: EventsWindowObserverNSView, context: Context) {
        nsView.onWindowAvailable = onWindowAvailable
        nsView.notifyIfWindowChanged()
    }
}

private final class EventsWindowObserverNSView: NSView {
    var onWindowAvailable: (@MainActor (NSWindow) -> Void)?
    private weak var lastRegisteredWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        notifyIfWindowChanged()
    }

    func notifyIfWindowChanged() {
        guard let window, lastRegisteredWindow !== window else { return }
        lastRegisteredWindow = window
        onWindowAvailable?(window)
    }
}

#Preview("Events Window") {
    let log = EventLog()
    log.record(severity: .info, category: .system, sourceName: "System", message: "Restoring 1 active bridge on launch")
    log.record(severity: .warning, category: .clock, sourceName: "Main Monitor", message: "Audio format or sample rate changed — rebuilding bridge")
    log.record(severity: .error, category: .permission, sourceName: "Main Monitor", message: "System Audio Recording permission required to tap \"Pro Tools HDX\"")
    let engine = InterceptorEngine(eventLog: log)
    let vm = AppViewModel(engine: engine)
    return EventsWindowView(viewModel: vm, appDelegate: AppDelegate())
        .frame(width: 740, height: 420)
}
