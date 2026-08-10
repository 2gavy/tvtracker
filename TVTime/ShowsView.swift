import SwiftUI
import UIKit

struct ShowsView: View {
    @EnvironmentObject private var store: ShowStore
    let scrollToTodayRequest: Int
    let onDiscover: () -> Void
    @State private var mediaFilter: MediaFilter = .all
    @State private var isHistoryLoaderArmed = false
    @State private var isLoadingHistoryFromScroll = false
    @State private var isHistoryBoundaryVisible = false
    @State private var pendingHistoryLoad: Task<Void, Never>?
    @State private var historyLoadTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            let sections = store.sections(matching: mediaFilter)
            ScrollViewReader { proxy in
                List {
                    if !sections.isEmpty && !store.hasLoadedHistory {
                        Color.clear
                            .frame(height: 1)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .background {
                                ScrollTopObserver { isAtTop in
                                    isHistoryBoundaryVisible = isAtTop
                                    scheduleHistoryLoadIfNeeded(using: proxy)
                                }
                            }
                    }

                    if sections.isEmpty {
                        EmptyScheduleView(
                            title: emptyTitle,
                            systemImage: emptySystemImage,
                            description: emptyDescription,
                            canDiscover: mediaFilter == .all && store.followedShows.isEmpty,
                            onDiscover: onDiscover
                        )
                        .listRowSeparator(.hidden)
                    } else {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.airings) { airing in
                                    AiringRow(airing: airing)
                                        .id(airing.id)
                                }
                            } header: {
                                SectionHeader(section: section)
                                    .id(section.id)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .animation(.snappy, value: mediaFilter)
                .refreshable {
                    await store.refreshFollowedSchedules(force: true)
                }
                .task {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    isHistoryLoaderArmed = true
                    scheduleHistoryLoadIfNeeded(using: proxy)
                }
                .onDisappear {
                    pendingHistoryLoad?.cancel()
                    historyLoadTask?.cancel()
                    isHistoryLoaderArmed = false
                }
                .onChange(of: mediaFilter) {
                    let updated = store.sections(matching: mediaFilter)
                    scrollToPresent(proxy, sections: updated, animated: true)
                }
                .onChange(of: store.timeZoneIdentifier) {
                    let updated = store.sections(matching: mediaFilter)
                    scrollToPresent(proxy, sections: updated, animated: true)
                }
                .onChange(of: scrollToTodayRequest) {
                    let updated = store.sections(matching: mediaFilter)
                    scrollToPresent(proxy, sections: updated, animated: false)
                }
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("TV Tracker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker("Media type", selection: $mediaFilter) {
                            ForEach(MediaFilter.allCases) { filter in
                                Label(filter.title, systemImage: filter.systemImage)
                                    .tag(filter)
                            }
                        }
                    } label: {
                        Image(systemName: mediaFilter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("Filter media")
                }
            }
        }
    }

    private var emptyTitle: String {
        switch mediaFilter {
        case .movies: "No movies scheduled"
        case .anime: "No anime scheduled"
        case .all, .tvShows: "Nothing scheduled"
        }
    }

    private var emptySystemImage: String {
        switch mediaFilter {
        case .movies: "film"
        case .anime: "sparkles.tv"
        case .all, .tvShows: "calendar.badge.clock"
        }
    }

    private var emptyDescription: String {
        if store.followedShows.isEmpty {
            return "Subscribe to a show and its upcoming dates will appear here."
        }
        return "There are no known dates for this filter yet."
    }

    private func loadHistoryIfNeeded(using proxy: ScrollViewProxy) {
        guard isHistoryLoaderArmed,
              isHistoryBoundaryVisible,
              !isLoadingHistoryFromScroll,
              !store.hasLoadedHistory else { return }

        let anchorID = store.sections(matching: mediaFilter)
            .first?.airings.first?.id
        isLoadingHistoryFromScroll = true
        historyLoadTask = Task {
            defer {
                isLoadingHistoryFromScroll = false
                historyLoadTask = nil
            }
            let revealedCurrentSeasons = store.revealCurrentSeasonHistory()
            if !revealedCurrentSeasons {
                await store.loadMoreHistory()
            }
            guard !Task.isCancelled else { return }
            await Task.yield()
            if let anchorID {
                proxy.scrollTo(anchorID, anchor: .top)
            }
        }
    }

    private func scheduleHistoryLoadIfNeeded(using proxy: ScrollViewProxy) {
        pendingHistoryLoad?.cancel()
        guard isHistoryLoaderArmed, isHistoryBoundaryVisible else { return }

        pendingHistoryLoad = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, isHistoryBoundaryVisible else { return }
            loadHistoryIfNeeded(using: proxy)
        }
    }

    private func scrollToPresent(
        _ proxy: ScrollViewProxy,
        sections: [AiringSection],
        animated: Bool
    ) {
        guard let id = anchorSectionID(in: sections) else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.28)) {
                proxy.scrollTo(id, anchor: .top)
            }
        } else {
            proxy.scrollTo(id, anchor: .top)
        }
    }

    private func anchorSectionID(in sections: [AiringSection]) -> String? {
        if let today = sections.first(where: { $0.title == "Today" }) { return today.id }

        let startOfToday = store.calendar.startOfDay(for: .now)
        if let next = sections.first(where: { section in
            section.airings.compactMap(\.airDate).min().map { $0 >= startOfToday } ?? false
        }) {
            return next.id
        }

        return sections.last(where: { !$0.airings.compactMap(\.airDate).isEmpty })?.id
            ?? sections.first?.id
    }
}

private struct ScrollTopObserver: UIViewRepresentable {
    let onTopChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTopChange: onTopChange)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        context.coordinator.attachWhenReady(from: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onTopChange = onTopChange
        context.coordinator.attachWhenReady(from: uiView)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var onTopChange: (Bool) -> Void
        private weak var scrollView: UIScrollView?
        private var observation: NSKeyValueObservation?
        private var lastReportedValue: Bool?
        private var attachmentAttempts = 0

        init(onTopChange: @escaping (Bool) -> Void) {
            self.onTopChange = onTopChange
        }

        func attachWhenReady(from view: UIView) {
            guard observation == nil else { return }
            var ancestor = view.superview
            while let candidate = ancestor {
                if let scrollView = candidate as? UIScrollView {
                    attach(to: scrollView)
                    return
                }
                ancestor = candidate.superview
            }

            guard attachmentAttempts < 5 else { return }
            attachmentAttempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak view] in
                guard let self, let view else { return }
                self.attachWhenReady(from: view)
            }
        }

        func detach() {
            observation?.invalidate()
            observation = nil
            scrollView = nil
        }

        private func attach(to scrollView: UIScrollView) {
            self.scrollView = scrollView
            observation = scrollView.observe(\.contentOffset, options: [.initial, .new]) {
                [weak self] scrollView, _ in
                self?.reportPosition(of: scrollView)
            }
        }

        private func reportPosition(of scrollView: UIScrollView) {
            let topOffset = -scrollView.adjustedContentInset.top
            let isAtTop = scrollView.contentOffset.y <= topOffset + 12
            guard isAtTop != lastReportedValue else { return }
            lastReportedValue = isAtTop
            DispatchQueue.main.async { [weak self] in
                self?.onTopChange(isAtTop)
            }
        }
    }
}

private struct EmptyScheduleView: View {
    let title: String
    let systemImage: String
    let description: String
    let canDiscover: Bool
    let onDiscover: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                Text(description)
            }

            if canDiscover {
                Button(action: onDiscover) {
                    Label("Find shows", systemImage: "sparkles.tv")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                        .background(AppTheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

private struct SectionHeader: View {
    let section: AiringSection
    private var isToday: Bool { section.title == "Today" }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(section.title)
                .font(.title3.weight(.bold))
                .textCase(nil)
                .foregroundStyle(isToday ? AppTheme.accent : Color.primary)

            if let subtitle = section.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .textCase(nil)
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

struct AiringRow: View {
    @EnvironmentObject private var store: ShowStore
    let airing: Airing

    private var show: Show { store.show(for: airing.showID) }
    private var isWatched: Bool { store.isWatched(airing) }
    private var canMarkWatched: Bool { store.canMarkWatched(airing) }
    private var canToggleWatched: Bool { canMarkWatched || isWatched }

    var body: some View {
        HStack(spacing: 12) {
            PosterView(show: show, width: 64, height: 92)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    if let date = airing.airDate {
                        Text(store.formattedScheduleDate(date))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppTheme.accent)
                    } else {
                        Text("DATE TBA")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.secondary)
                    }
                    Text(show.mediaType == .movie ? "MOVIE" : airing.code)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                }

                Text(show.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(airing.title)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Image(systemName: "play.rectangle.fill")
                    Text(airing.service)
                    if airing.runtime > 0 {
                        Text("· \(airing.runtime) min")
                    }
                }
                .font(.caption2)
                .foregroundStyle(Color.secondary)
            }
            .opacity(isWatched ? 0.68 : 1)

            Spacer(minLength: 4)

            if canToggleWatched {
                Button {
                    withAnimation(.snappy) { store.toggleWatched(airing) }
                } label: {
                    Image(systemName: isWatched ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isWatched ? AppTheme.completed : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isWatched ? "Mark unwatched" : "Mark watched")
            }
        }
        .animation(.snappy, value: isWatched)
        .padding(.vertical, 5)
        .listRowBackground(Color(uiColor: .systemBackground))
        .modifier(SeasonCompletionMenu(show: show, airing: airing))
    }
}

private struct SeasonCompletionMenu: ViewModifier {
    @EnvironmentObject private var store: ShowStore
    let show: Show
    let airing: Airing

    func body(content: Content) -> some View {
        content.contextMenu {
            if show.mediaType == .tvShow,
               store.canMarkAiredSeasonEpisodes(containing: airing) {
                Button {
                    if store.canMarkSeasonWatched(containing: airing) {
                        store.markSeasonWatched(containing: airing)
                    } else {
                        store.markAiredSeasonEpisodesWatched(containing: airing)
                    }
                } label: {
                    Label(
                        store.canMarkSeasonWatched(containing: airing)
                            ? "Mark season watched"
                            : "Mark aired episodes watched",
                        systemImage: "checkmark.circle.fill"
                    )
                }
            }

            Button(role: .destructive) {
                store.toggleFollow(show)
            } label: {
                Label("Unsubscribe", systemImage: "minus.circle")
            }
        } preview: {
            SeasonWatchPreview(show: show, airing: airing)
        }
    }
}

private struct SeasonWatchPreview: View {
    let show: Show
    let airing: Airing

    var body: some View {
        HStack(spacing: 14) {
            PosterView(show: show, width: 64, height: 92)

            VStack(alignment: .leading, spacing: 5) {
                Text(show.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(airing.season > 0 ? "Season \(airing.season)" : show.mediaType.title)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(16)
        .frame(width: 260, alignment: .leading)
        .background(Color(uiColor: .systemBackground))
    }
}

struct PosterView: View {
    let show: Show
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Group {
            if let imageName = show.imageName,
               let path = Bundle.main.path(forResource: imageName, ofType: "jpg", inDirectory: "Posters"),
               let poster = UIImage(contentsOfFile: path) {
                Image(uiImage: poster)
                    .resizable()
                    .scaledToFill()
            } else if let imageURL = show.imageURL {
                CachedPosterImage(
                    url: imageURL,
                    contentMode: .fill,
                    maxPixelSize: min(360, max(160, Int(height * 2)))
                ) {
                    posterPlaceholder
                }
            } else {
                posterPlaceholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1))
        }
        .clipped()
    }

    private var posterPlaceholder: some View {
        ZStack {
            Color(hex: show.tintHex).opacity(0.28)
            Image(systemName: "play.tv")
                .foregroundStyle(Color(hex: show.tintHex))
        }
    }
}
