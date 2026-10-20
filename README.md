# Prime Cue Recorder

Mac app that sets up ProPresenter MIDI cues in Loop Community Prime each week: the playlist item cue that selects each song (note 18) and the lyric slide cues (note 19, velocity = slide number), recorded by clicking through the slides while the song plays.

**Each week**

1. Open ProPresenter (Settings › Network › Enable Network; enter the port in the app) and the app. It loads the newest Prime setlist and ProPresenter's current playlist.
2. Every song is matched to its playlist item by title. Fix any match in the song's Playlist Item card.
3. Songs without lyric cues are flagged. For each one: press **Record**, play the song in Prime from the top, click through the slides in ProPresenter, press **Stop**, check the cues, and **Keep**. It moves on to the next song that needs lyrics. Items with no music (tempo 0, like announcements) are skipped.
4. Press **Save to Prime**. Prime must be closed while saving; the app waits for it. Then open Prime, check the songs, and save them to the cloud.

**Timing.** The first click in each ProPresenter group (Verse 1, Chorus…) is lined up with the matching Prime section, so a take needs to play straight through without stopping or looping. Every cue then fires 0.5 seconds before the click (adjustable) to cover MIDI delay between Prime and ProPresenter.

**Songs without sections** (uploaded songs, songs with tempo changes) are timed by the clock instead. Prime stores their cues as a fraction of the whole song, so the app reads the song's length from its downloaded stems, and after recording asks where the first slide lands in the song (it starts from the recorded time, which is right when Record and Play were pressed together). The rest follow the clicks.

**Shift Lyric Cues** (toolbar, ⇆) moves every saved lyric cue in this week's setlist earlier or later by a set amount (0.5 s earlier by default), for when slides keep changing a little late. Playlist item cues stay put, and it can also move new recordings by the same amount. A cue pushed past the start of its section moves into the section before it when both play once; in a section that repeats it stops at the edge instead, and the sheet says how many did. Shifting back the other way undoes it.

**Saved Cues** (on a song that already has lyric cues) lists where each slide fires, with its words from ProPresenter. Click a slide to move it (− / +, or ← / →), change its slide number, remove it (Delete), or add the next slide after it; ↑ / ↓ pick another. Or move a group at once: every slide, the lyrics only, or only Interlude and blank slides (so lyrics can come in a touch early while instrumental slides wait). The review screen after recording has the same list. Changes are written with Save to Prime.

**Slips.** A slide replaced within 0.6 s is ignored, and a slide clicked early and taken back (17, 18, back to 17, 18 again) is left out in favor of the later click; the review list shows it struck through so it can be put back. A section change clicked well off the beat is left out of the timing when at least three others agree.

**Full Disk Access.** Prime keeps its library in its own app container, and without Full Disk Access macOS asks to Allow opening it every launch. On first launch the app explains this and opens System Settings › Privacy & Security › Full Disk Access; it notices the switch on its own. Not Now is remembered, and Settings › Prime Library can turn it on later.

**Updates.** Sparkle checks once a day; Settings › Updates and a toolbar icon show when a new version is out. The update window lists every version newer than the one installed (the feed carries the last eight versions' notes and the app trims the rest).

**Settings.** Note numbers (19 lyrics, 18 playlist item), MIDI channel, the early-fire time, and whether playlist headers count when numbering items are all adjustable.

**Safety.** Saving backs up the whole Prime database to `~/Documents/PrimeBackups` first and only replaces those two notes on Prime's lyrics bus. Lights and other cues are kept, and songs with more than one playlist cue (medleys) are left alone. Lyric saves also write the same baseline file as the `prime-midi-cues` skill, so `prime.py learn` still works.

The landing page (prime.joshcirre.com) is in `site/`, served by a Cloudflare Worker with static assets: `npx wrangler deploy`. The social preview image `site/og.png` is rendered from `art/og.html`: `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --hide-scrollbars --force-device-scale-factor=1 --window-size=1200,630 --screenshot="$PWD/site/og.png" "file://$PWD/art/og.html"`.

## Build

```sh
swift test
./scripts/build-app.sh       # dist/Prime Cue Recorder.app and the installer DMG, for this Mac only
```

`build-app.sh` also takes `SIGN_ID` (a Developer ID identity) and `NOTARY_PROFILE` (a saved notarytool login) or an App Store Connect API key (`APPLE_API_KEY_PATH`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER`) to sign and notarize for other Macs. The DMG is made with [dmgbuild](https://github.com/dmgbuild/dmgbuild) through `uv`. The icon and installer background are SVGs in `art/`.

## Releasing

```sh
$EDITOR release-notes/0.3.1.md    # what's new: shown in the update window and on the release page
scripts/release.sh 0.3.1             # build, sign, notarize, tag, upload to a draft release
gh release edit v0.3.1 --repo crosschurch/prime-cue-recorder --draft=false --latest   # ship it
```

Signing and notarization come from `~/.config/jcss/release.env` on Josh's Mac. Publishing the draft is what ships it. Installed copies check `releases/latest/download/appcast.xml` once a day with [Sparkle](https://sparkle-project.org) (and on Prime Cue Recorder › Check for Updates…), and offer the new version; they never update mid-recording. The website's download button follows the latest release too. `--publish` does both steps at once.

The feed is signed with the update key at `~/.config/prime-cue-recorder/sparkle-ed25519.key` (an ed25519 seed, base64; its public half is `SUPublicEDKey` in `build-app.sh`). Keep a copy somewhere safe: without it, installed copies can't be updated, and a new key needs everyone to reinstall by hand. Only release builds update themselves; `UPDATE_FEED=<url>` points a local build at a feed to test updating.

`PCR_DEMO=review swift run` (also `ready`, `recording`, `waiting`, `saved`, `shift`; add `-clock` for a song without sections) opens a screen with sample data, without ProPresenter or Prime.

`PRIME_TEST_DB=/path/to/copy.sqlite swift test` also tests saving against a copy of a real Prime database.
