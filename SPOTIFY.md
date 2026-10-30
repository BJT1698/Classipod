# ClassiPod for Spotify

This fork replaces local music with your Spotify library. The iPod UI stays the
same; audio is played by the Spotify app on the phone, which ClassiPod drives
through the Spotify Web API (Spotify Connect). Android only.

## Requirements

- Spotify Premium (playback control via the Web API requires it, and since
  February 2026 the owner of a Development Mode app must be Premium too).
- The Spotify app installed and logged in on the phone.
- A Spotify developer app (free): Development Mode allows up to 5 users, who
  must be added by name and email in the dashboard.

## Setup

1. Create an app at <https://developer.spotify.com/dashboard>.
   - Redirect URI: `classipod://spotify-callback`
   - APIs used: Web API.
   - Under *User Management*, add the Spotify account(s) that will use it.
2. Build with your Client ID:

   ```sh
   flutter run --flavor production -t lib/main.dart \
     --dart-define=SPOTIFY_CLIENT_ID=<your client id>
   ```

On first launch ClassiPod opens the Spotify login page, then syncs your library
in the background. Sign in/out and resync from *Settings → Library*.

## What ends up in the library

- Liked Songs, saved albums (all tracks), and the playlists you own or
  collaborate on. Spotify no longer returns the contents of other people's
  playlists to Development Mode apps, so followed playlists are skipped.
- Spotify playlists appear under *Music → Playlists* and are refreshed on every
  sync. Local edits to them are overwritten by the next sync.
- Genres are empty: Spotify does not expose genres on tracks.

## How playback works

ClassiPod keeps its own queue (shuffle songs/albums, repeat) and sends Spotify
the next 50 tracks of it each time playback starts; it polls the player every
2 seconds while the app is in the foreground and follows along. If the phone
is not registered as a Spotify Connect device, ClassiPod opens the Spotify app
to wake it up.

Known limits:

- In the background ClassiPod stops polling. Spotify keeps playing the current
  50-track window, but the queue is not extended until you reopen ClassiPod.
- If you start something else from the Spotify app, ClassiPod stops tracking
  it until you play from ClassiPod again.
- The media notification and lock-screen controls are Spotify's own.
