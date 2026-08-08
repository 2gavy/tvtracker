import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var store: ShowStore
    @AppStorage("darkModeEnabled") private var darkModeEnabled = true
    @Binding var allowsTabSwipe: Bool
    @State private var isShowingSubscriptions = false
    @State private var isShowingWatchedEpisodes = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    StatsGrid(
                        onSubscriptions: { isShowingSubscriptions = true },
                        onWatchedEpisodes: { isShowingWatchedEpisodes = true }
                    )
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)

                Section("Schedule") {
                    NavigationLink {
                        TimeZonePickerView(selection: $store.timeZoneIdentifier)
                            .onAppear { allowsTabSwipe = false }
                            .onDisappear { allowsTabSwipe = true }
                    } label: {
                        LabeledContent(
                            "Time zone",
                            value: TimeZonePickerView.displayName(for: store.timeZoneIdentifier)
                        )
                    }
                }

                Section("Appearance") {
                    Toggle("Dark mode", systemImage: "circle.lefthalf.filled", isOn: $darkModeEnabled)
                }

            }
            .navigationTitle("Settings")
            .navigationDestination(isPresented: $isShowingSubscriptions) {
                FollowingView()
                    .onAppear { allowsTabSwipe = false }
                    .onDisappear { allowsTabSwipe = true }
            }
            .navigationDestination(isPresented: $isShowingWatchedEpisodes) {
                WatchedEpisodesView()
                    .onAppear { allowsTabSwipe = false }
                    .onDisappear { allowsTabSwipe = true }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        AboutView()
                            .onAppear { allowsTabSwipe = false }
                            .onDisappear { allowsTabSwipe = true }
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("About TV Tracker")
                }
            }
        }
    }
}

private struct StatsGrid: View {
    @EnvironmentObject private var store: ShowStore
    let onSubscriptions: () -> Void
    let onWatchedEpisodes: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSubscriptions) {
                StatMetric(
                    value: "\(store.followedShows.count)",
                    label: "Subscribed"
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Subscribed shows, \(store.followedShows.count)")

            Divider()
                .frame(height: 44)

            Button(action: onWatchedEpisodes) {
                StatMetric(
                    value: "\(store.watchedAiringIDs.count)",
                    label: "Episodes"
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Episodes watched, \(store.watchedAiringIDs.count)")

            Divider()
                .frame(height: 44)

            StatMetric(
                value: store.watchedDuration,
                label: "Watch time"
            )
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Watched time, \(store.watchedDuration)")
        }
        .padding(16)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.separator.opacity(0.3), lineWidth: 0.5)
        }
    }
}

private struct StatMetric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.title.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(AppTheme.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
}

private struct TimeZonePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String
    @State private var searchText = ""

    private static let recommendedIdentifiers = [
        "Asia/Singapore",
        "Asia/Tokyo",
        "Asia/Seoul",
        "Asia/Hong_Kong",
        "Asia/Shanghai",
        "Asia/Bangkok",
        "Asia/Kolkata",
        "Australia/Sydney",
        "Europe/London",
        "America/New_York",
        "America/Los_Angeles"
    ]

    private var matchingIdentifiers: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return TimeZone.knownTimeZoneIdentifiers.filter {
                !Self.recommendedIdentifiers.contains($0)
            }
        }
        return TimeZone.knownTimeZoneIdentifiers.filter { identifier in
            identifier.localizedCaseInsensitiveContains(query)
                || Self.displayName(for: identifier).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            if searchText.isEmpty {
                Section("Recommended") {
                    ForEach(Self.recommendedIdentifiers, id: \.self) { identifier in
                        timeZoneRow(identifier)
                    }
                }
            }

            Section(searchText.isEmpty ? "All time zones" : "Results") {
                ForEach(matchingIdentifiers, id: \.self) { identifier in
                    timeZoneRow(identifier)
                }
            }
        }
        .navigationTitle("Time Zone")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search city or region")
    }

    @ViewBuilder
    private func timeZoneRow(_ identifier: String) -> some View {
        Button {
            selection = identifier
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.displayName(for: identifier))
                        .foregroundStyle(.primary)
                    Text(identifier.replacingOccurrences(of: "_", with: " "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(Self.offsetText(for: identifier))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)

                if selection == identifier {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func displayName(for identifier: String) -> String {
        identifier
            .split(separator: "/")
            .last
            .map(String.init)?
            .replacingOccurrences(of: "_", with: " ")
            ?? identifier
    }

    private static func offsetText(for identifier: String) -> String {
        guard let timeZone = TimeZone(identifier: identifier) else { return "GMT" }
        let totalMinutes = timeZone.secondsFromGMT(for: .now) / 60
        let sign = totalMinutes >= 0 ? "+" : "-"
        let hours = abs(totalMinutes) / 60
        let minutes = abs(totalMinutes) % 60
        return minutes == 0
            ? "GMT\(sign)\(hours)"
            : String(format: "GMT%@%d:%02d", sign, hours, minutes)
    }
}

private struct AboutView: View {
    private var version: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(shortVersion) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("TV Tracker")
                        .font(.title2.weight(.bold))
                    Text("Never miss the next episode of your shows.")
                        .foregroundStyle(.secondary)
                    Text(version)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Help & legal") {
                Link("Privacy Policy", destination: URL(string: "https://github.com/2gavy/tvtime/blob/main/PRIVACY.md")!)
                Link("Support", destination: URL(string: "https://github.com/2gavy/tvtime/issues")!)
            }

            Section("Credits") {
                Link("TV information provided by TVmaze", destination: URL(string: "https://www.tvmaze.com")!)

                HStack(spacing: 14) {
                    Image("TMDBLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 28)

                    Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WatchedEpisodesView: View {
    @EnvironmentObject private var store: ShowStore

    var body: some View {
        Group {
            if store.watchedAirings.isEmpty {
                ContentUnavailableView(
                    "No watched episodes",
                    systemImage: "checkmark.circle",
                    description: Text("Episodes you mark as watched will appear here.")
                )
            } else {
                List(store.watchedAirings) { airing in
                    AiringRow(airing: airing)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Episodes watched")
    }
}
