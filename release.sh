#!/usr/bin/env zsh
# release.sh — Build, verify, package, and publish a WaxOn/WaxOff release.
#
# Usage: ./release.sh <version>
#   e.g. ./release.sh 1.2.0
#
# Requires: xcodebuild, hdiutil, gh (GitHub CLI), git

set -euo pipefail

REPO="sevmorris/WaxOnWaxOff"

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
MANUAL_IDX="$PROJECT_DIR/docs/manual/index.html"
LANDING_IDX="$PROJECT_DIR/docs/index.html"

# ── Helpers ───────────────────────────────────────────────────────────────────
step()  { echo "\n▶ $*"; }
ok()    { echo "  ✓ $*"; }
fail()  { echo "\n  ✗ $*" >&2; exit 1; }

cleanup() {
    rm -rf "$STAGING" "$MOUNT" "$DERIVED_DATA"
    rm -f "$DMG"
}

# ── Preflight ─────────────────────────────────────────────────────────────────
step "Preflight checks"
for cmd in xcodebuild hdiutil gh git codesign xcrun curl; do
    command -v $cmd &>/dev/null || fail "'$cmd' not found in PATH"
done
ok "Tools present"

cd "$PROJECT_DIR"

if [[ -n "$(git status --porcelain)" ]]; then
    fail "Working tree is dirty — commit or stash changes before releasing"
fi
ok "Working tree clean"

if git tag | grep -q "^${TAG}$"; then
    fail "Tag $TAG already exists — has this version been released?"
fi
ok "Tag $TAG is available"

# ── Version bump ──────────────────────────────────────────────────────────────
step "Bumping version to $VERSION"
CURRENT=$(grep MARKETING_VERSION "$PROJECT/project.pbxproj" | head -1 | grep -o '[0-9][0-9.]*')
if [[ "$CURRENT" == "$VERSION" ]]; then
    ok "Already at $VERSION"
else
    # Escape dots (and other regex metacharacters) so pre-release versions like
    # "1.7.0-rc.1" don't cause sed pattern mismatches.
    ESC_CURRENT=$(printf '%s' "$CURRENT" | sed 's/[.[\*^$]/\\&/g')
    ESC_VERSION=$(printf '%s'  "$VERSION" | sed 's/[.[\*^$]/\\&/g')
    sed -i '' "s/MARKETING_VERSION = ${ESC_CURRENT};/MARKETING_VERSION = ${ESC_VERSION};/g" \
        "$PROJECT/project.pbxproj"
    ok "Bumped $CURRENT → $VERSION"
    git add "$PROJECT/project.pbxproj"
    git commit -m "Bump version to $VERSION"
    ok "Committed version bump"
fi

step "Bumping build number"
BUILD_NUM=$(grep 'CURRENT_PROJECT_VERSION = ' "$PROJECT/project.pbxproj" | head -1 | grep -o '[0-9][0-9]*')
NEXT_BUILD=$((BUILD_NUM + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION = ${BUILD_NUM};/CURRENT_PROJECT_VERSION = ${NEXT_BUILD};/g" \
    "$PROJECT/project.pbxproj"
ok "Build number ${BUILD_NUM} → ${NEXT_BUILD}"

step "Fetching FFmpeg binaries"
chmod +x "$PROJECT_DIR/scripts/fetch-ffmpeg.sh"
"$PROJECT_DIR/scripts/fetch-ffmpeg.sh"
ok "FFmpeg present"

# ── Build ─────────────────────────────────────────────────────────────────────
step "Building (clean, Release)"
rm -rf "$DERIVED_DATA"
rm -rf ~/Library/Caches/com.apple.dt.Xcode*(N) 2>/dev/null || true
rm -rf ~/Library/Developer/Xcode/DerivedData/ModuleCache*(N) 2>/dev/null || true
ok "Xcode caches cleared"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -quiet
[[ -d "$APP_PATH" ]] || fail "Build did not produce $APP_PATH"
ok "Build complete"

# ── Sign ──────────────────────────────────────────────────────────────────────
step "Codesigning binaries and app"
IDENTITY="Developer ID Application: Seven Morris (T9RLNAXPWU)"
ENTITLEMENTS="$PROJECT_DIR/WaxOnWaxOff/WaxOnWaxOff.entitlements"

# Sign bundled binaries with Hardened Runtime
codesign --force --options runtime --sign "$IDENTITY" "$APP_PATH/Contents/Resources/ffmpeg"
codesign --force --options runtime --sign "$IDENTITY" "$APP_PATH/Contents/Resources/ffprobe"
# Note: rnnoise is a model file (text), no signing needed.

# Sign the app bundle
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | tail -3
ok "Codesigning complete"

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
ln -s /Applications "$STAGING/Applications"
ok "App and Applications alias staged"

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

# ── Notarize ──────────────────────────────────────────────────────────────────
step "Notarizing DMG"
# Assumes a profile named 'WoWoNotary' exists.
# Setup: xcrun notarytool store-credentials WoWoNotary --apple-id <email> --team-id T9RLNAXPWU
xcrun notarytool submit "$DMG" --wait --keychain-profile "WoWoNotary"
xcrun stapler staple "$DMG"
ok "Notarization complete"

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

# ── Update docs (README + manual) to point at the new version ────────────────
# Per project convention: rewrite unconditionally and let `git status --porcelain`
# decide whether anything actually changed before committing.
step "Updating docs to ${TAG}"

# Manual: download button + sidebar version badge.
sed -i '' "s|WaxOnWaxOff-v[0-9][0-9.]*\.dmg|WaxOnWaxOff-${TAG}.dmg|g" "$MANUAL_IDX"
sed -i '' "s|>Download v[0-9][0-9.]*<|>Download ${TAG}<|g" "$MANUAL_IDX"
sed -i '' "s|Manual — v[0-9][0-9.]*|Manual — ${TAG}|g" "$MANUAL_IDX"

# README.md: HTML hyperlink, plain "**Version:**" label, and any markdown form.
sed -i '' "s|WaxOnWaxOff-v[0-9][0-9.]*\.dmg|WaxOnWaxOff-${TAG}.dmg|g" "$PROJECT_DIR/README.md"
sed -i '' "s|<strong>Version:</strong> [0-9][0-9.]*|<strong>Version:</strong> ${VERSION}|g" "$PROJECT_DIR/README.md"
sed -i '' "s|\*\*Version:\*\* [0-9][0-9.]*|**Version:** ${VERSION}|g" "$PROJECT_DIR/README.md"
sed -i '' "s|\[Download v[0-9][0-9.]* (DMG)\]|[Download ${TAG} (DMG)]|g" "$PROJECT_DIR/README.md"

# Landing page: download button URLs and button text.
sed -i '' "s|WaxOnWaxOff-v[0-9][0-9.]*\.dmg|WaxOnWaxOff-${TAG}.dmg|g" "$LANDING_IDX"
sed -i '' "s|>Download v[0-9][0-9.]*<|>Download ${TAG}<|g" "$LANDING_IDX"

# Sanity-check: nothing should still reference the old version.
if grep -E "WaxOnWaxOff-v[0-9]+\.[0-9]+\.[0-9]+\.dmg" "$MANUAL_IDX" "$LANDING_IDX" "$PROJECT_DIR/README.md" \
        | grep -v "${TAG}\.dmg" >/dev/null; then
    fail "Stale version references remain after rewrite — check sed patterns"
fi

if [[ -n "$(git status --porcelain)" ]]; then
    # Also pick up the build-number bump from the pbxproj so it actually lands
    # in the repo (otherwise the build bump stays uncommitted across runs).
    git add "$PROJECT/project.pbxproj" "$MANUAL_IDX" "$LANDING_IDX" "$PROJECT_DIR/README.md"
    git commit -m "docs: update download link to ${TAG}"
    ok "Docs point to ${TAG}"
else
    ok "Docs already up to date"
fi

# ── Tag and push ──────────────────────────────────────────────────────────────
step "Tagging and pushing"
git tag "$TAG"
# Resolve the tracked remote/branch so this works from any branch (e.g. a
# worktree branch whose name differs from its upstream). Fall back to
# `origin` + current branch when no upstream is configured; `-u` sets it
# on first push so subsequent runs resolve cleanly.
if UPSTREAM=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null); then
    REMOTE="${UPSTREAM%%/*}"
    BRANCH="${UPSTREAM#*/}"
else
    REMOTE="origin"
    BRANCH=$(git branch --show-current)
fi
git push -u "$REMOTE" "HEAD:$BRANCH" || fail "Failed to push branch to $REMOTE/$BRANCH"
git push "$REMOTE" "$TAG" || fail "Failed to push tag $TAG to $REMOTE (branch was pushed; tag is local only)"
ok "Pushed $TAG to $REMOTE/$BRANCH"

# ── GitHub release ────────────────────────────────────────────────────────────
step "Creating GitHub release"
PREV_TAG=$(git tag --sort=-creatordate | grep -v "^${TAG}$" | head -1 || true)
if [[ -n "$PREV_TAG" ]]; then
    CHANGES=$(git log "${PREV_TAG}..HEAD" --pretty=format:"- %s" \
        | grep -v "^- Bump version" \
        | grep -v "^- docs: update download link" || true)
else
    CHANGES=$(git log --pretty=format:"- %s" \
        | grep -v "^- Bump version" \
        | grep -v "^- docs: update download link" || true)
fi
[[ -n "$CHANGES" ]] || CHANGES="- Initial release"
RELEASE_NOTES="**[Manual](https://sevmorris.github.io/WaxOnWaxOff/)**

### Changes
${CHANGES}"
gh release create "$TAG" "$DMG" \
    --repo "$REPO" \
    --title "WaxOn/WaxOff $TAG" \
    --notes "$RELEASE_NOTES"
ok "Release published"

# ── Remove old releases (keep the ${KEEP_RELEASES} most recent) ───────────────
KEEP_RELEASES=5
step "Removing old releases (keeping ${KEEP_RELEASES} most recent)"
OLD_TAGS=$(gh release list --repo "$REPO" --limit 100 --json tagName \
    --jq '.[].tagName' | tail -n +$((KEEP_RELEASES + 1)) || true)
if [[ -z "$OLD_TAGS" ]]; then
    ok "No old releases to remove"
else
    while IFS= read -r old_tag; do
        gh release delete "$old_tag" --repo "$REPO" --yes --cleanup-tag 2>/dev/null || true
        git tag -d "$old_tag" 2>/dev/null || true
        ok "Removed $old_tag"
    done <<< "$OLD_TAGS"
fi

# ── Remove old Pages deployments ─────────────────────────────────────────────
step "Removing old Pages deployments"
ALL_DEPLOY_IDS=$(gh api "repos/$REPO/deployments?environment=github-pages&per_page=100" \
    --jq '.[].id')
OLD_DEPLOY_IDS=$(echo "$ALL_DEPLOY_IDS" | tail -n +2)
if [[ -z "$OLD_DEPLOY_IDS" ]]; then
    ok "No old deployments to remove"
else
    COUNT=0
    while IFS= read -r deploy_id; do
        gh api -X POST "repos/$REPO/deployments/${deploy_id}/statuses" \
            -f state=inactive --silent 2>/dev/null || true
        gh api -X DELETE "repos/$REPO/deployments/${deploy_id}" --silent 2>/dev/null || true
        COUNT=$((COUNT + 1))
    done <<< "$OLD_DEPLOY_IDS"
    ok "Removed $COUNT old deployment(s)"
fi

# ── Clean up temp files ───────────────────────────────────────────────────────
step "Cleaning up"
rm -rf "$STAGING" "$MOUNT" "$DERIVED_DATA"
rm -f "$DMG"
ok "Temp files removed"

# ── Open release page ─────────────────────────────────────────────────────────
RELEASE_URL="https://github.com/${REPO}/releases/tag/${TAG}"
echo "\n✓ WaxOn/WaxOff $TAG released successfully."
echo "  $RELEASE_URL"
open "$RELEASE_URL"
