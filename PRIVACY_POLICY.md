# Privacy Policy for FastScrobbler

**Effective date:** February 26, 2026

FastScrobbler is an iOS and macOS app for scrobbling Apple Music / Music app plays to Last.fm.

## Summary

- FastScrobbler does **not** run a developer-owned backend service.
- The app sends track metadata to **Last.fm** only after you connect your Last.fm account and use scrobbling features, including Shortcuts and Control Center widgets.
- FastScrobbler does **not** use third-party analytics SDKs and does **not** track you across apps and websites.

## Information the app accesses

### Apple Music / Media Library (on-device)

With your permission, FastScrobbler reads Apple Music / Media Library data to identify the current track and, if enabled, import recent plays for scrobbling. This can include:

- Track metadata (artist, title, album)
- Album artist (when available)
- Track duration
- Playback timestamps (e.g., "last played" time)
- Local media identifiers (e.g., persistent IDs)

FastScrobbler uses this information to determine what to submit to Last.fm. Local media identifiers are used only on-device.

### Music app automation (macOS)

On macOS, FastScrobbler uses Apple Events (Automation) to read now-playing metadata from the Music app. This can include:

- Track metadata (artist, title, album)
- Track duration and playback position

If Automation permission is denied, the macOS app cannot read what is playing or scrobble it.

### Apple Music favorites (optional, on-device)

FastScrobbler can infer whether the current track is favorited in Apple Music, for example through the "Favorite Songs" playlist. If "Love Apple Music favourites on Last.fm" is enabled, the app may use that on-device favorite status to send a `track.love` request to Last.fm after scrobbling.

### Last.fm account connection

When you connect Last.fm, FastScrobbler uses Apple’s authentication flow to obtain a Last.fm session key for your account.

## Information the app stores (on your device)

FastScrobbler stores the following data locally:

- **Last.fm session key**: stored in Apple Keychain services (iOS/macOS).
- **Last.fm username**: stored locally (UserDefaults) after it is fetched from Last.fm.
- **Retry backlog** (queued scrobbles): stored locally so scrobbles can be retried when the network is available (including timestamps used for scrobbling).
- **Recent scrobble log**: stored locally to show recent activity in the app.
- **App settings**: such as scrobble threshold and metadata preferences, stored locally.
- **Listening history import state (iOS)**: stored locally to avoid re-importing the same plays (may include local media identifiers and play counts).

FastScrobbler does not intentionally store your full music library; it stores only what is needed for queued scrobbles and recent history.

Some data may be stored in an app group container so the iOS app and its extensions, such as Live Activities and Control Center widgets, can share the same on-device state.

## Information the app shares

### Last.fm

When you use FastScrobbler, the app sends requests directly from your device to Last.fm’s API. Depending on the feature, those requests may include:

- Artist and track title
- Album (if available)
- Track duration (if available)
- A timestamp representing when playback started / occurred (for scrobbles)

Last.fm also receives standard network information, such as your IP address, as part of providing its service. Your use of Last.fm is governed by Last.fm’s own terms and privacy policy.

### Apple

FastScrobbler uses Apple system frameworks, including AuthenticationServices, Background Tasks, Widgets, and Live Activities. Apple may receive standard device and service information as part of operating iOS/macOS. FastScrobbler does not send your music listening data to any developer-run server.

### No sale of data

FastScrobbler does not sell your personal information.

## Tracking and advertising

- FastScrobbler does not show ads.
- FastScrobbler does not use the advertising identifier (IDFA).
- FastScrobbler does not use third-party analytics or tracking SDKs.

## Data retention and deletion

- You can disconnect from Last.fm within the app, which removes the locally stored Last.fm session key.
- Queued scrobbles remain on-device until they are successfully submitted or until you remove the app.
- To remove all locally stored app data, delete FastScrobbler from your device.

Scrobbles already submitted to Last.fm are stored by Last.fm under its own policies. You can manage or delete them through Last.fm.

## Security

FastScrobbler uses HTTPS when communicating with Last.fm. The Last.fm session key is stored in Apple Keychain services.

## Children’s privacy

FastScrobbler is not directed to children and does not knowingly collect personal information from children.

## Changes to this policy

If this policy changes, the "Effective date" above will be updated.

## Contact

For questions about this policy, contact the developer through the project’s support channel, such as the GitHub repository issues page where the app is distributed.
