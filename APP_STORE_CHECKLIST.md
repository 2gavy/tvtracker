# TV Tracker App Store Checklist

TV Tracker launches as a free App Store download with unlimited tracking. It has no subscription, login requirement, or in-app purchase in version 1.0.

## Required Before Submission

- [ ] Confirm `TV Tracker` branding with appropriate trademark searches in launch markets.
- [x] Register `com.noriesloo.tvtracker` in the Apple Developer portal.
- [x] Enable the iCloud key-value storage capability for `com.noriesloo.tvtracker` before creating the distribution profile.
- [ ] Confirm the intended TMDB use is covered by provider permission before including TMDB content in the release build.
- [ ] Confirm the production TMDB credential architecture. An xcconfig prevents accidental Git commits, but a token embedded in an iOS app can still be extracted; use a provider-approved client credential or a protected proxy.
- [ ] Review TVmaze CC BY-SA ShareAlike obligations for the final use; in-app attribution is already present.
- [ ] Host `PRIVACY.md` and `SUPPORT.md` at stable public HTTPS URLs and update the in-app links if the repository URLs change.
- [ ] Provide a private support email address in App Store Connect.
- [ ] Complete App Privacy answers based on the final binary and every third-party service it contacts.
- [ ] Complete the age-rating questionnaire for entertainment catalogue content.
- [ ] Create current iPhone screenshots that show the chronological schedule, Discover search, show details, and Settings.
- [ ] Replace the repository screenshot if its branding or UI no longer matches the release build.
- [ ] Test first launch with no existing `UserDefaults`, dark and light mode, Singapore and US time zones, offline mode, and large Dynamic Type.
- [ ] Test search for `Survivor`, at least one current anime, and representative Asian and streaming titles.
- [ ] On two devices signed into the same iCloud account, verify subscribe, unsubscribe, watched status, time-zone changes, deletion, and delete/reinstall restoration.
- [ ] Archive a Release build with no secrets committed to Git and validate it in Xcode Organizer.
- [ ] Test the uploaded build through TestFlight before submitting for review.

## Already Reflected In The App

- [x] No paywall or purchase UI in version 1.0.
- [x] No mandatory account or login.
- [x] No music, theme-song playback, advertising, or analytics SDK.
- [x] AniList and Apple Search catalogue integrations removed from the release target.
- [x] New users start with no fake subscriptions or schedule entries.
- [x] Privacy, support, provider credits, and the app version are accessible from Settings.
- [x] API credentials are excluded from Git.
- [x] A valid privacy manifest declares the app's `UserDefaults` required-reason API usage.
- [x] The app declares that it does not use non-exempt encryption.
- [x] TVmaze attribution and the CC BY-SA 4.0 license are linked from the in-app Credits section.
