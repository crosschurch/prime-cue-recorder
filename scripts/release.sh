#!/bin/sh
# Releases a version: scripts/release.sh 0.3.1 [--publish]
#
# Write release-notes/0.3.1.md first (Markdown): installed copies show it in the update window,
# and it becomes the GitHub release notes.
#
# Builds, signs and notarizes the app and installer, writes the signed update feed, tags the
# commit and uploads the DMG, a zip and appcast.xml to a draft GitHub release. Publishing the
# draft (--publish, or `gh release edit v0.3.1 --draft=false`) is what ships it: every copy
# checks releases/latest/download/appcast.xml once a day, and the website's download link
# follows the latest release too.
#
# Signing and notarization come from ~/.config/jcss/release.env (the JCSS setup on this Mac)
# when it's there; otherwise set SIGN_ID and NOTARY_PROFILE or APPLE_API_KEY_* yourself.
set -eu
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> [--publish]}"
VERSION="${VERSION#v}"
PUBLISH="${2:-}"
REPO=crosschurch/prime-cue-recorder
TAG="v$VERSION"

if [ ! -f "release-notes/$VERSION.md" ]; then
    echo "Write release-notes/$VERSION.md first: it's what the update window and the release page show."; exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
    echo "Commit your changes first, so the release matches a commit."; exit 1
fi
if git rev-parse "$TAG" >/dev/null 2>&1; then
    [ "$(git rev-parse "$TAG^{commit}")" = "$(git rev-parse HEAD)" ] || { echo "$TAG is already another commit"; exit 1; }
else
    git tag "$TAG"
fi
git push origin HEAD "$TAG"

if [ -f "$HOME/.config/jcss/release.env" ]; then
    set -a; . "$HOME/.config/jcss/release.env"; set +a
    unset JCSS_KEYCHAIN_PASSWORD
    SIGN_ID="${SIGN_ID:-${JCSS_SIGN_IDENTITY:-}}"
fi
export SIGN_ID VERSION
export RELEASE=1
scripts/build-app.sh

if ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release create "$TAG" --repo "$REPO" --draft --title "Prime Cue Recorder $VERSION" \
        --notes-file "release-notes/$VERSION.md"
fi
gh release upload "$TAG" dist/PrimeCueRecorder.dmg dist/PrimeCueRecorder.zip dist/appcast.xml \
    --repo "$REPO" --clobber
if [ "$PUBLISH" = "--publish" ]; then
    gh release edit "$TAG" --repo "$REPO" --draft=false --latest
    echo "Published $TAG: copies out there will offer it within a day."
else
    echo "Uploaded to the draft $TAG. Publish it to ship the update:"
    echo "  gh release edit $TAG --repo $REPO --draft=false --latest"
fi
