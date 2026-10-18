# Prime Cue Recorder

Mac app that sets up ProPresenter MIDI cues in Loop Community Prime each week: the playlist item cue that selects each song (note 18) and the lyric slide cues (note 19, velocity = slide number), recorded by clicking through the slides while the song plays.

**Each week**

1. Open ProPresenter (Settings › Network › Enable Network; enter the port in the app) and the app. It loads the newest Prime setlist and ProPresenter's current playlist.
2. Every song is matched to its playlist item by title. Fix any match in the song's Playlist Item card.
3. Songs without lyric cues are flagged. For each one: press **Record**, play the song in Prime from the top, click through the slides in ProPresenter, press **Stop**, check the cues, and **Keep**. It moves on to the next song that needs lyrics.
4. Press **Save to Prime**. Prime must be closed while saving; the app waits for it. Then open Prime, check the songs, and save them to the cloud.

**Timing.** The first click in each ProPresenter group (Verse 1, Chorus…) is lined up with the matching Prime section, so a take needs to play straight through without stopping or looping. Every cue then fires 0.5 seconds before the click (adjustable) to cover MIDI delay between Prime and ProPresenter.

**Settings.** Note numbers (19 lyrics, 18 playlist item), MIDI channel, the early-fire time, and whether playlist headers count when numbering items are all adjustable.

**Safety.** Saving backs up the whole Prime database to `~/Documents/PrimeBackups` first and only replaces those two notes on Prime's lyrics bus. Lights and other cues are kept, and songs with more than one playlist cue (medleys) are left alone. Lyric saves also write the same baseline file as the `prime-midi-cues` skill, so `prime.py learn` still works.

The landing page (prime.joshcirre.com) is in `site/`, served by a Cloudflare Worker with static assets: `npx wrangler deploy`.

## Build

```sh
swift test
./scripts/build-app.sh                                                     # this Mac only
SIGN_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=notary ./scripts/build-app.sh  # signed + notarized zip for other Macs
```

`NOTARY_PROFILE` is a saved notarytool login (`xcrun notarytool store-credentials notary`). An App Store Connect API key works instead: set `APPLE_API_KEY_PATH`, `APPLE_API_KEY_ID` and `APPLE_API_ISSUER`.

`PCR_DEMO=review swift run` (also `ready`, `recording`, `waiting`, `saved`) opens a screen with sample data, without ProPresenter or Prime.

`PRIME_TEST_DB=/path/to/copy.sqlite swift test` also tests saving against a copy of a real Prime database.
