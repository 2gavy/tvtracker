import SwiftUI

struct ShowsView: View {
    @EnvironmentObject private var store: ShowStore
    @State private var mediaFilter: MediaFilter = .all

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
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
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
                }
                .onChange(of: mediaFilter) {
                    let updated = store.sections(matching: mediaFilter)
                    scrollToPresent(proxy, sections: updated, animated: true)
                }
                .onChange(of: store.timeZoneIdentifier) {
                    let updated = store.sections(matching: mediaFilter)
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
