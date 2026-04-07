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
MANUAL="$PROJECT_DIR/docs/index.html"
MANUAL_IDX="$PROJECT_DIR/docs/manual/index.html"

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
for cmd in xcodebuild hdiutil gh git; do
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
rm -rf ~/Library/Caches/com.apple.dt.Xcode* 2>/dev/null || true
rm -rf ~/Library/Developer/Xcode/DerivedData/ModuleCache* 2>/dev/null || true
ok "Xcode caches cleared"
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

# ── Update manual download link and version badge ─────────────────────────────
step "Updating manual download link"
sed -i '' "s|WaxOnWaxOff-v[0-9][0-9.]*\.dmg\">Download v[0-9][0-9.]*|WaxOnWaxOff-${TAG}.dmg\">Download ${TAG}|g" "$MANUAL" "$MANUAL_IDX"
sed -i '' "s|WaxOnWaxOff-v[0-9][0-9.]*\.dmg\" class=\"nav-cta\">Download|WaxOnWaxOff-${TAG}.dmg\" class=\"nav-cta\">Download|g" "$MANUAL"
sed -i '' "s|Manual — v[0-9][0-9.]*|Manual — ${TAG}|g" "$MANUAL_IDX"
sed -i '' "s|\[Download v[0-9][0-9.]* (DMG)\](https://github.com/sevmorris/WaxOnWaxOff/releases/latest/download/WaxOnWaxOff-v[0-9][0-9.]*.dmg)|\[Download ${TAG} (DMG)\](https://github.com/sevmorris/WaxOnWaxOff/releases/latest/download/WaxOnWaxOff-${TAG}.dmg)|g" README.md
if [[ -n "$(git status --porcelain)" ]]; then
    git add "$MANUAL" "$MANUAL_IDX" README.md
    git commit -m "docs: update download link to ${TAG}"
    ok "Manual points to ${TAG}"
else
    ok "Docs already up to date"
fi

# ── Tag and push ──────────────────────────────────────────────────────────────
step "Tagging and pushing"
git tag "$TAG"
git push
git push origin "$TAG"
ok "Pushed $TAG"

# ── GitHub release ────────────────────────────────────────────────────────────
step "Creating GitHub release"
PREV_TAG=$(git tag --sort=-creatordate | grep -v "^${TAG}$" | head -1)
if [[ -n "$PREV_TAG" ]]; then
    CHANGES=$(git log "${PREV_TAG}..HEAD" --pretty=format:"- %s" \
        | grep -v "^- Bump version" \
        | grep -v "^- docs: update download link")
else
    CHANGES=$(git log --pretty=format:"- %s" \
        | grep -v "^- Bump version" \
        | grep -v "^- docs: update download link")
fi
RELEASE_NOTES="**[Manual](https://sevmorris.github.io/WaxOnWaxOff/)**

### Changes
${CHANGES}"
gh release create "$TAG" "$DMG" \
    --repo "$REPO" \
    --title "WaxOn/WaxOff $TAG" \
    --notes "$RELEASE_NOTES"
ok "Release published"

# ── Remove old releases ───────────────────────────────────────────────────────
step "Removing old releases"
OLD_TAGS=$(gh release list --repo "$REPO" --limit 100 --json tagName \
    --jq '.[].tagName' | grep -v "^${TAG}$" || true)
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
