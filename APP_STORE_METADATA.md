# TV Tracker App Store Metadata

This document is ready to paste into App Store Connect after the licensing and account gates in `APP_STORE_CHECKLIST.md` are complete.

## Product Positioning

- Pain: People miss episodes because release dates are scattered across services.
- Product: Upcoming episodes for your shows, in one list.
- Core job: Tell subscribers what airs next and when.
- Price: Paid upfront, planned at US$0.99, with no login or in-app purchase.

## App Information

- Name: `TV Tracker`
- Primary language: English (U.S.)
- Bundle ID: `app.tvtracker.timeline`
- SKU suggestion: `tvtracker-ios-001`
- Primary category: Entertainment
- Secondary category: Lifestyle
- Content rights: Confirm provider licensing before answering Yes.
- Copyright: `2026 <rights holder or legal entity>`

The App Store name is only confirmed when the app record is created. If `TV Tracker` is unavailable, use `TV Tracker: Episode Dates` without changing the on-device display name.

## Version 1.0

### Subtitle

`Upcoming episodes, one list`

### Promotional Text

`Follow the shows you care about and see every confirmed episode date in one clean timeline.`

### Description

TV Tracker puts upcoming episodes from all your subscribed shows into one chronological list.

Subscribe once, then open the app to see what aired last week, what is on today, and what is coming next. Dates follow your selected time zone, and watched episodes stay clearly marked.

Discover new television, anime, and streaming releases. Open a title for its synopsis, subscribe with one tap, and manage every subscription from Settings.

Your subscriptions and watched progress stay private. There is no TV Tracker account, advertising, analytics, or recurring subscription. Your tracking data is stored on your device and can sync through your private iCloud account.

Features:
- One chronological episode timeline
- Confirmed dates in your chosen time zone
- Search and discovery across a broad TV catalogue
- TV, anime, and movie filters
- Episode and season watched controls
- Private iCloud restoration across reinstalls
- Dark and light appearance

TV Tracker is an independent app and is not affiliated with TV Time or Whip Media.

### Keywords

`tv tracker,episode tracker,show calendar,upcoming episodes,movie tracker,anime,watchlist`

### What's New

`Initial release.`

## URLs

- Privacy Policy: `https://github.com/2gavy/tvtime/blob/main/PRIVACY.md`
- Support URL: `https://github.com/2gavy/tvtime/blob/main/SUPPORT.md`
- Marketing URL: Optional for version 1.0

Confirm that the repository is public and these pages load while signed out before submission.

## App Review Notes

TV Tracker is a paid-upfront app. It contains no login, account registration, in-app purchase, subscription, advertising, or analytics SDK.

The app opens directly to the Shows timeline. On a new install, use Discover to search for a show and tap Subscribe. Return to Shows to see its episode schedule. Long-press an aired episode to mark the aired episodes in that season as watched. Settings contains subscriptions, watched history, time-zone selection, privacy, support, and data-provider credits.

Subscriptions and watched progress are stored locally and in the user's private iCloud key-value store when iCloud is available. The developer does not operate a user-profile backend.

Network access is used to retrieve public catalogue metadata, schedules, and poster images from the credited providers.

## App Privacy Draft

The current app contains no advertising, analytics, tracking, login, contact form, or developer-operated backend. Local and private iCloud tracking state is not accessible to the developer.

Before selecting `Data Not Collected`, confirm in writing how every production catalogue provider handles API search terms, IP addresses, and request logs. If a provider retains search queries or identifiable network data, disclose the corresponding data types and App Functionality purpose in App Store Connect.

Tracking: No.

## Screenshot Set

Use a consistent status bar and realistic subscriptions. Do not show copyrighted music playback or provider credentials.

1. Shows on Today: `Every episode. One timeline.`
2. Upcoming dates: `Know exactly what's next.`
3. Discover search: `Find the shows you actually watch.`
4. Show synopsis: `Decide in seconds.`
5. Settings activity: `Your watch history, kept private.`

Capture current iPhone screenshots after the final licensed provider configuration is frozen.

Use one accepted 6.9-inch portrait size for the full set: `1320 x 2868`, `1290 x 2796`, or `1260 x 2736` pixels. Screenshots must not contain transparency.

## Required Account Actions

1. Enroll in the paid Apple Developer Program if the current team is still a Personal Team.
2. Accept the latest agreements in App Store Connect Business.
3. Complete paid-app banking and tax forms.
4. Register `app.tvtracker.timeline` and enable iCloud key-value storage.
5. Create the iOS app record before uploading the first build.
6. Set price and availability.
7. Complete age rating, content rights, privacy answers, and review contact information.
