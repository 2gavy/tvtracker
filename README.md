# TV Time

A subscription-first SwiftUI prototype for following upcoming TV episodes.

## Open

1. Open `TVTime.xcodeproj` in Xcode 16 or newer.
2. Choose an iPhone simulator.
3. Run the `TVTime` scheme.

The prototype uses sample schedule data and bundled TVmaze poster images. Subscriptions and watched episodes persist in `UserDefaults`.

## Product shape

- **Shows**: one combined TV and movie timeline with a media-type filter; pull firmly past the top to load previous subscribed seasons on demand.
- **Theme music**: automatically shuffle matching 30-second soundtrack previews across the subscribed lineup, including a large WWE and wider pro-wrestling entrance theme pool, controlled by a single on/off preference in Profile.
- **Discover**: browse daily-changing trending and personalized recommendation carousels, filter by content type and streaming service, or search TVmaze and Apple's movie catalog, then subscribe with one tap.
- **Profile**: manage subscriptions and watched episodes, see total watch time, and control reminders, appearance, and local data.

TV and anime search results plus episode schedules come from TVmaze's free public API. Movie search and metadata use Apple's public Search API. The browse grid also includes a curated starter set of films and anime.
