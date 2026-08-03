import SwiftUI

struct ShowsView: View {
    @EnvironmentObject private var store: ShowStore
    @State private var mediaFilter: MediaFilter = .all
    @State private var timelineIndex = 0
    @State private var isScrubbingTimeline = false
    @State private var isTimelineVisible = false
    @State private var isAtScheduleBottom = false
    @State private var timelineHideTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            let sections = store.sections(matching: mediaFilter)
            ScrollViewReader { proxy in
                List {
                    if sections.isEmpty {
                        ContentUnavailableView(
                            emptyTitle,
                            systemImage: emptySystemImage
                        )
                        .listRowSeparator(.hidden)
                    } else {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.airings) { airing in
                                    AiringRow(airing: airing)
                                }
                            } header: {
                                SectionHeader(section: section)
                                    .id(section.id)
                                    .background {
                                        GeometryReader { geometry in
                                            Color.clear.preference(
                                                key: SectionPositionPreferenceKey.self,
                                                value: [section.id: geometry.frame(in: .named("shows-scroll")).minY]
                                            )
                                        }
                                    }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .coordinateSpace(name: "shows-scroll")
                .contentMargins(.trailing, showsTimeline(sections) ? 16 : 0, for: .scrollContent)
                .animation(.snappy, value: mediaFilter)
                .refreshable {
                    if !store.hasLoadedHistory {
                        await store.loadPreviousSeasons()
                    } else {
                        await store.refreshFollowedSchedules()
                    }
                }
                .onAppear {
                    scrollToPresent(proxy, sections: sections, animated: false)
                    timelineIndex = anchorSectionIndex(in: sections) ?? 0
                }
                .onChange(of: mediaFilter) {
                    let updated = store.sections(matching: mediaFilter)
                    timelineIndex = anchorSectionIndex(in: updated) ?? 0
                    scrollToPresent(proxy, sections: updated, animated: true)
                }
                .onChange(of: store.timeZoneIdentifier) {
                    let updated = store.sections(matching: mediaFilter)
                    timelineIndex = anchorSectionIndex(in: updated) ?? 0
                    scrollToPresent(proxy, sections: updated, animated: true)
                }
                .onChange(of: store.isRefreshingSchedules) { _, isRefreshing in
                    if !isRefreshing {
                        scrollToPresent(
                            proxy,
                            sections: store.sections(matching: mediaFilter),
                            animated: true
                        )
                    }
                }
                .onPreferenceChange(SectionPositionPreferenceKey.self) { positions in
                    guard !isScrubbingTimeline, !isAtScheduleBottom,
                          let nearest = positions.min(by: { abs($0.value) < abs($1.value) }),
                          let index = sections.firstIndex(where: { $0.id == nearest.key }) else { return }
                    timelineIndex = index
                }
                .modifier(ScrollActivityModifier { isScrolling in
                    if isScrolling {
                        revealTimeline()
                    } else {
                        scheduleTimelineHide()
                    }
                })
                .modifier(ScrollBottomModifier { isAtBottom in
                    if isAtBottom {
                        isAtScheduleBottom = true
                        guard !isScrubbingTimeline, !sections.isEmpty else { return }
                        timelineIndex = sections.count - 1
                    } else if !isScrubbingTimeline {
                        isAtScheduleBottom = false
                    }
                })
                .overlay(alignment: .trailing) {
                    if showsTimeline(sections) && isTimelineVisible {
                        TimelineScrubber(
                            sections: sections,
                            selectedIndex: timelineIndex,
                            onScrubbingChanged: { isScrubbing in
                                isScrubbingTimeline = isScrubbing
                                if isScrubbing {
                                    revealTimeline()
                                } else {
                                    scheduleTimelineHide()
                                }
                            },
                            onSelect: { index, animated in
                                guard sections.indices.contains(index) else { return }
                                timelineIndex = index
                                isAtScheduleBottom = index == sections.count - 1
                                if animated {
                                    withAnimation(.snappy) {
                                        proxy.scrollTo(sections[index].id, anchor: .top)
                                    }
                                } else {
                                    proxy.scrollTo(sections[index].id, anchor: .top)
                                }
                            }
                        )
                        .padding(.trailing, 11)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.2), value: isTimelineVisible)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("TV Time")
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

    private func scrollToPresent(
        _ proxy: ScrollViewProxy,
        sections: [AiringSection],
        animated: Bool
    ) {
        guard let id = anchorSectionID(in: sections) else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.snappy) { proxy.scrollTo(id, anchor: .top) }
            } else {
                proxy.scrollTo(id, anchor: .top)
            }
        }
    }

    private func showsTimeline(_ sections: [AiringSection]) -> Bool {
        sections.count > 2 && sections.reduce(0) { $0 + $1.airings.count } > 6
    }

    private func revealTimeline() {
        timelineHideTask?.cancel()
        if !isTimelineVisible { isTimelineVisible = true }
    }

    private func scheduleTimelineHide() {
        timelineHideTask?.cancel()
        timelineHideTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_600))
            guard !Task.isCancelled, !isScrubbingTimeline else { return }
            isTimelineVisible = false
        }
    }

    private func anchorSectionIndex(in sections: [AiringSection]) -> Int? {
        guard let id = anchorSectionID(in: sections) else { return nil }
        return sections.firstIndex { $0.id == id }
    }

    private func anchorSectionID(in sections: [AiringSection]) -> String? {
        if let thisWeek = sections.first(where: { $0.title == "This week" }) { return thisWeek.id }
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

private struct SectionPositionPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}

private struct ScrollActivityModifier: ViewModifier {
    let onChange: (Bool) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, phase in
                onChange(phase.isScrolling)
            }
        } else {
            content.simultaneousGesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        guard abs(value.translation.height) > abs(value.translation.width) else { return }
                        onChange(true)
                    }
                    .onEnded { _ in onChange(false) }
            )
        }
    }
}

private struct ScrollBottomModifier: ViewModifier {
    let onChange: (Bool) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height + geometry.contentInsets.bottom - 12
            } action: { _, isAtBottom in
                onChange(isAtBottom)
            }
        } else {
            content
        }
    }
}

private struct TimelineScrubber: View {
    let sections: [AiringSection]
    let selectedIndex: Int
    let onScrubbingChanged: (Bool) -> Void
    let onSelect: (Int, Bool) -> Void

    @State private var isDragging = false
    private let trackHeight: CGFloat = 218
    private let thumbSize: CGFloat = 18

    private var safeIndex: Int {
        min(max(selectedIndex, 0), max(sections.count - 1, 0))
    }

    private var progress: CGFloat {
        guard sections.count > 1 else { return 0 }
        return CGFloat(safeIndex) / CGFloat(sections.count - 1)
    }

    var body: some View {
        HStack(spacing: 8) {
            if isDragging {
                Text(sections[safeIndex].title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(AppTheme.separator, lineWidth: 0.5)
                    }
                    .lineLimit(1)
                    .transition(.opacity)
            }

            VStack(spacing: 5) {
                ZStack(alignment: .top) {
                    Capsule()
                        .fill(Color.primary.opacity(0.18))
                        .frame(width: 3, height: trackHeight)

                    Capsule()
                        .fill(AppTheme.accent.opacity(0.48))
                        .frame(width: 3, height: max(thumbSize / 2, progress * trackHeight))

                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: thumbSize, height: thumbSize)
                        .overlay {
                            Circle()
                                .fill(AppTheme.accent.opacity(0.82))
                                .padding(4)
                        }
                        .offset(y: progress * (trackHeight - thumbSize))
                        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                }
                .frame(width: 24, height: trackHeight)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                onScrubbingChanged(true)
                            }
                            let fraction = min(max((value.location.y - thumbSize / 2) / (trackHeight - thumbSize), 0), 1)
                            let index: Int
                            if fraction >= 0.84 {
                                index = sections.count - 1
                            } else if fraction <= 0.12 {
                                index = 0
                            } else {
                                index = Int((fraction * CGFloat(sections.count - 1)).rounded())
                            }
                            if index != safeIndex { onSelect(index, false) }
                        }
                        .onEnded { _ in
                            isDragging = false
                            onScrubbingChanged(false)
                        }
                )
                .accessibilityRepresentation {
                    Slider(
                        value: Binding(
                            get: { Double(safeIndex) },
                            set: { onSelect(Int($0.rounded()), true) }
                        ),
                        in: 0...Double(sections.count - 1),
                        step: 1
                    )
                    .accessibilityLabel("Schedule timeline")
                    .accessibilityValue(sections[safeIndex].title)
                }
            }
        }
        .animation(.easeOut(duration: 0.14), value: isDragging)
    }
}

private struct SectionHeader: View {
    let section: AiringSection
    private var isCurrentWeek: Bool { section.title == "This week" }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(section.title)
                .font(.title3.weight(.bold))
                .textCase(nil)
                .foregroundStyle(isCurrentWeek ? AppTheme.accent : Color.primary)

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

            Button {
                withAnimation(.snappy) { store.toggleWatched(airing) }
            } label: {
                Image(systemName: isWatched ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isWatched ? AppTheme.accent : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isWatched ? "Mark unwatched" : "Mark watched")
        }
        .animation(.snappy, value: isWatched)
        .padding(.vertical, 5)
        .listRowBackground(Color(uiColor: .systemBackground))
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
                AsyncImage(url: imageURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        posterPlaceholder
                    }
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
