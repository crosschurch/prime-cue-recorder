# Prime Cue Recorder

Mac app that creates ProPresenter lyric cues (MIDI note 19, velocity = slide number) in Loop Community Prime by recording you clicking through the slides while the song plays.

1. Turn on ProPresenter's network API (Settings > Network > Enable Network) and enter its port in the app.
2. Pick the setlist and song, press **Record**, play the song in Prime from the top, and click through the slides in ProPresenter.
3. Press **Stop**, check the cues, and **Save to Prime**. Prime must be closed while saving; the app waits for it.
4. Open Prime, play the song to check, and save it to the cloud.

The first click in each ProPresenter group (Verse 1, Chorus…) is lined up with the matching Prime section, so the take needs to play straight through without stopping or looping. Lyric slides fire a set number of beats early (default 2); blank slides fire where they were clicked.

Saving backs up the whole Prime database to `~/Documents/PrimeBackups` first and only replaces note-19 lyric cues. Lights and other cues are kept. It also writes the same baseline file as the `prime-midi-cues` skill, so `prime.py learn` still works.

## Build

```sh
swift test
./scripts/build-app.sh                                                     # this Mac only
SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/build-app.sh  # for other Macs (then notarize)
```

`PRIME_TEST_DB=/path/to/copy.sqlite swift test` also tests saving against a copy of a real Prime database.
