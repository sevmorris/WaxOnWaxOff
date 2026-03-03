#!/usr/bin/env zsh
# release.sh — Build, verify, package, and publish a WaxOn/WaxOff release.
#
# Usage: ./release.sh <version>
#   e.g. ./release.sh 1.2.0
#
# Requires: xcodebuild, hdiutil, gh (GitHub CLI), git

set -euo pipefail

# ── Args ──────────────────────────────────────────────────────────────────────
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <version>"
    echo "  e.g. $0 1.2.0"
    exit 1
fi

VERSION="$1"
TAG="v${VERSION}"
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="$SCRIPT_DIR"
PROJECT="$PROJECT_DIR/WaxOnWaxOff.xcodeproj"
SCHEME="WaxOnWaxOff"
DERIVED_DATA="/tmp/waxon_build_${VERSION}"
APP_PATH="$DERIVED_DATA/Build/Products/Release/WaxOnWaxOff.app"
STAGING="/tmp/waxon_dmg_${VERSION}"
DMG="/tmp/WaxOnWaxOff-${TAG}.dmg"
MOUNT="/tmp/waxon_verify_${VERSION}"

# ── Helpers ───────────────────────────────────────────────────────────────────
step()  { echo "\n▶ $*"; }
ok()    { echo "  ✓ $*"; }
fail()  { echo "\n  ✗ $*" >&2; exit 1; }

# ── Preflight ─────────────────────────────────────────────────────────────────
step "Preflight checks"
for cmd in xcodebuild hdiutil gh git; do
    command -v $cmd &>/dev/null || fail "'$cmd' not found in PATH"
done
ok "Tools present"

cd "$PROJECT_DIR"

if [[ -n "$(git status --porcelain)" ]]; then
    fail "Working tree is dirty — commit or stash changes before releasing"
fi
ok "Working tree clean"

# ── Version bump ──────────────────────────────────────────────────────────────
step "Bumping version to $VERSION"
CURRENT=$(grep MARKETING_VERSION "$PROJECT/project.pbxproj" | head -1 | grep -o '[0-9][0-9.]*')
if [[ "$CURRENT" == "$VERSION" ]]; then
    ok "Already at $VERSION — skipping bump"
else
    sed -i '' "s/MARKETING_VERSION = ${CURRENT};/MARKETING_VERSION = ${VERSION};/g" \
        "$PROJECT/project.pbxproj"
    ok "Bumped $CURRENT → $VERSION"
    git add "$PROJECT/project.pbxproj"
    git commit -m "Bump version to $VERSION"
    ok "Committed version bump"
fi

# ── Build ─────────────────────────────────────────────────────────────────────
step "Building (clean, Release)"
rm -rf "$DERIVED_DATA"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -quiet
ok "Build complete"

# ── Verify app version ────────────────────────────────────────────────────────
step "Verifying built app version"
BUILT_VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)
[[ "$BUILT_VERSION" == "$VERSION" ]] || \
    fail "App version mismatch: expected $VERSION, got $BUILT_VERSION"
ok "App reports $BUILT_VERSION"

# ── Stage DMG contents ────────────────────────────────────────────────────────
step "Staging DMG contents"
rm -rf "$STAGING"
mkdir "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
cp "$PROJECT_DIR/README.txt" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
ok "App, README.txt, Applications alias"

# ── Create DMG ────────────────────────────────────────────────────────────────
step "Creating DMG"
rm -f "$DMG"
hdiutil create \
    -volname "WaxOn/WaxOff $TAG" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    -o "$DMG" \
    -quiet
ok "Created $(du -sh $DMG | cut -f1) DMG"

# ── Verify DMG ────────────────────────────────────────────────────────────────
step "Verifying DMG contents"
rm -rf "$MOUNT"
mkdir "$MOUNT"
hdiutil attach "$DMG" -mountpoint "$MOUNT" -quiet -nobrowse
DMG_VERSION=$(defaults read "$MOUNT/WaxOnWaxOff.app/Contents/Info.plist" CFBundleShortVersionString)
hdiutil detach "$MOUNT" -quiet
[[ "$DMG_VERSION" == "$VERSION" ]] || \
    fail "DMG version mismatch: expected $VERSION, got $DMG_VERSION"
ok "DMG contains $DMG_VERSION"

# ── Tag and push ──────────────────────────────────────────────────────────────
step "Tagging and pushing"
git tag "$TAG"
git push
git push origin "$TAG"
ok "Pushed $TAG"

# ── GitHub release ────────────────────────────────────────────────────────────
step "Creating GitHub release"
RELEASE_NOTES="**[Manual](https://sevmorris.github.io/WaxOnWaxOff/)**"
gh release create "$TAG" "$DMG" \
    --repo sevmorris/WaxOnWaxOff \
    --title "WaxOn/WaxOff $TAG" \
    --notes "$RELEASE_NOTES"
ok "Release published"

# ── Done ──────────────────────────────────────────────────────────────────────
echo "\n✓ WaxOn/WaxOff $TAG released successfully."
echo "  https://github.com/sevmorris/WaxOnWaxOff/releases/tag/$TAG"
