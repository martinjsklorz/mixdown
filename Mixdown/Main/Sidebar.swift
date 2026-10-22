import MixdownCore
import SwiftUI

// The controls at the top of the main window's sidebar, above the notes. See `MainView`.

/// The sidebar's search field, drawn by hand so Record fits beside it: `searchable` in the
/// sidebar takes its whole width.
struct SidebarSearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search Recordings", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: SidebarControl.height)
        .background(.quaternary, in: Capsule())
        // ⌘F, as `searchable` had it, from an invisible button: hidden ones don't take shortcuts.
        .background {
            Button("Search Recordings") { isFocused = true }
                .keyboardShortcut("f")
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}

/// Shows the recorder, beside the search field, and says what the recorder is doing while it's
/// busy.
struct SidebarRecordButton: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        SidebarSectionButton("Record", systemImage: "record.circle", destination: .recorder, help: "Record (⌘1)") {
            RecorderStatusBadge(coordinator: coordinator)
        }
    }
}

/// Shows `destination`. Highlighted like a selected note while it's shown, with `badge` beside
/// its icon.
struct SidebarSectionButton<Badge: View>: View {
    @Environment(MainNavigation.self) private var navigation
    let title: String
    let systemImage: String
    let destination: MainNavigation.Destination
    let help: String
    @ViewBuilder let badge: Badge

    init(
        _ title: String,
        systemImage: String,
        destination: MainNavigation.Destination,
        help: String,
        @ViewBuilder badge: () -> Badge
    ) {
        self.title = title
        self.systemImage = systemImage
        self.destination = destination
        self.help = help
        self.badge = badge()
    }

    /// Without a badge, e.g. for Chat.
    init(
        _ title: String,
        systemImage: String,
        destination: MainNavigation.Destination,
        help: String
    ) where Badge == EmptyView {
        self.init(title, systemImage: systemImage, destination: destination, help: help) { EmptyView() }
    }

    var body: some View {
        let isSelected = navigation.destination == destination
        Button {
            navigation.destination = destination
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.headline)
                badge
            }
            .padding(.horizontal, 10)
            .frame(minWidth: SidebarControl.height, minHeight: SidebarControl.height)
            .background(
                isSelected ? AnyShapeStyle(Color("NoteSelection")) : AnyShapeStyle(.quaternary),
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(help)
    }
}

enum SidebarControl {
    static let height: CGFloat = 30
}

/// What the recorder is doing, next to the Record icon: the time while recording, progress
/// while downloading, transcribing, translating or summarizing.
struct RecorderStatusBadge: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        switch coordinator.phase {
        case .recording(let startedAt):
            Text(startedAt, style: .timer)
                .monospacedDigit()
                .foregroundStyle(.red)
        case .paused(let recorded):
            Text(ProgressText.elapsed(Int(recorded)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        case .preparingModel(let progress), .transcribing(let progress):
            Text(progress.formatted(.percent.precision(.fractionLength(0))))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        case .startingCapture, .translating, .summarizing:
            ProgressView()
                .controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
        case .idle:
            EmptyView()
        }
    }
}
