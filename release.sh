#!/usr/bin/env zsh
# release.sh — Build, verify, package, and publish a WaxOn/WaxOff release.
#
# Usage: ./release.sh <version> [--allow-red-ci]
#   e.g. ./release.sh 1.2.0
#
# Requires: xcodebuild, hdiutil, gh (GitHub CLI), git

set -euo pipefail

REPO="sevmorris/WaxOnWaxOff"

# ── Args ──────────────────────────────────────────────────────────────────────
# One positional argument (the version) plus an optional flag in either position.
# Anything else — including no arguments, or a second positional that isn't the
# flag — still fails with usage, as it did before the flag existed.
ALLOW_RED_CI=0
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --allow-red-ci) ALLOW_RED_CI=1 ;;
        *)              ARGS+=("$arg") ;;
    esac
done

if [[ ${#ARGS[@]} -ne 1 ]]; then
    echo "Usage: $0 <version> [--allow-red-ci]"
    echo "  e.g. $0 1.2.0"
    echo ""
    echo "  --allow-red-ci  Release even when CI is not green for HEAD."
    exit 1
fi

VERSION="${ARGS[1]}"
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
    # Uses ${VAR:-} so the trap fires cleanly even if the script exits before
    # the path variables are defined (e.g. early exit on argument-error).
    [[ -d "${STAGING:-}" ]]      && rm -rf -- "$STAGING"      || true
    [[ -d "${MOUNT:-}" ]]        && rm -rf -- "$MOUNT"        || true
    [[ -d "${DERIVED_DATA:-}" ]] && rm -rf -- "$DERIVED_DATA" || true
    [[ -f "${DMG:-}" ]]          && rm -f  -- "$DMG"          || true
}
trap cleanup EXIT

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

# ── CI gate ───────────────────────────────────────────────────────────────────
# Refuse to cut a release from a commit CI has not proven green. This sits at the
# end of preflight deliberately: everything below mutates or costs real time —
# project.pbxproj is rewritten, the Xcode caches are cleared, a clean Release
# build runs, the DMG is notarized, and the branch and tag are pushed. A red CI
# should cost the operator one API call, not a notarization round-trip.
#
# HEAD is the right SHA to check. The working-tree-clean assertion above
# guarantees HEAD fully describes what will be built, and the "Bump version" and
# "docs: update download link" commits this script makes later do not exist yet —
# so no run can exist for them. This gate proves the code CI tested is green; it
# cannot vouch for those two release-mechanics commits, which reach CI only when
# the push below triggers a fresh run.
#
# The filter is on the workflow's path, not its name: `name:` is a field inside
# ci.yml that can be edited without anyone thinking about this gate. It is also
# not optional — an unfiltered head_sha query also returns GitHub's built-in
# "pages build and deployment" run, which is green on commits where CI is red.
#
# Multiple CI runs can exist for one SHA (a pull_request run and a push run, for
# instance). The most recent by created_at wins.
RELEASE_SHA=$(git rev-parse HEAD)
step "Verifying CI for $RELEASE_SHA"

# `gh` itself is already proven present by the tool loop above; authentication is not.
CI_STATUS=""; CI_CONCLUSION=""; CI_URL=""; CI_PROBLEM=""; CI_RUN=""
if ! gh auth status &>/dev/null; then
    CI_PROBLEM="gh is not authenticated (run 'gh auth login')"
elif ! CI_RUN=$(gh api "repos/${REPO}/actions/runs?head_sha=${RELEASE_SHA}&per_page=100" \
        --jq '[.workflow_runs[] | select(.path == ".github/workflows/ci.yml")]
              | sort_by(.created_at) | last | select(. != null)
              | "\(.status)\t\(.conclusion)\t\(.html_url)"' 2>/dev/null); then
    CI_PROBLEM="could not query GitHub Actions — check network access and repository permissions"
elif [[ -z "$CI_RUN" ]]; then
    CI_PROBLEM="no CI run exists for this commit (has it been pushed to GitHub?)"
else
    CI_STATUS="${CI_RUN%%$'\t'*}"
    CI_REST="${CI_RUN#*$'\t'}"
    CI_CONCLUSION="${CI_REST%%$'\t'*}"
    CI_URL="${CI_REST#*$'\t'}"
    if [[ "$CI_STATUS" != "completed" ]]; then
        CI_PROBLEM="CI has not finished — status '${CI_STATUS}', no conclusion yet"
    elif [[ "$CI_CONCLUSION" != "success" ]]; then
        CI_PROBLEM="CI concluded '${CI_CONCLUSION}'"
    fi
fi

if [[ -n "$CI_PROBLEM" ]]; then
    if (( ALLOW_RED_CI )); then
        echo "\n  ⚠ --allow-red-ci — releasing past a failed CI gate" >&2
        echo "      commit:  $RELEASE_SHA" >&2
        echo "      reason:  $CI_PROBLEM" >&2
        [[ -n "$CI_URL" ]] && echo "      run:     $CI_URL" >&2
        ok "CI gate overridden"
    else
        echo "      commit:  $RELEASE_SHA" >&2
        [[ -n "$CI_URL" ]] && echo "      run:     $CI_URL" >&2
        fail "$CI_PROBLEM — refusing to release $TAG; re-run with --allow-red-ci to override"
    fi
else
    ok "CI green for $RELEASE_SHA"
    ok "$CI_URL"
fi

# ── Version bump ──────────────────────────────────────────────────────────────
step "Bumping version to $VERSION"
# project.pbxproj carries MARKETING_VERSION once per build configuration. Taking
# head -1 is only safe if they all agree — otherwise the bump reads one value,
# rewrites only the configurations that happen to match it, and ships a build
# whose version depends on which configuration Xcode chose. Assert first.
VERSION_VALUES=$(grep -o 'MARKETING_VERSION = [^;]*;' "$PROJECT/project.pbxproj" | sort -u)
VERSION_COUNT=$(printf '%s\n' "$VERSION_VALUES" | grep -c .)
if [[ "$VERSION_COUNT" -ne 1 ]]; then
    echo "$VERSION_VALUES" >&2
    fail "MARKETING_VERSION disagrees across build configurations (${VERSION_COUNT} distinct values) — reconcile before releasing"
fi
ok "MARKETING_VERSION agrees across all $(grep -c 'MARKETING_VERSION' "$PROJECT/project.pbxproj") occurrences"

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
    ok "Bumped $CURRENT → $VERSION (commit deferred until after notarization)"
fi

step "Bumping build number"
BUILD_NUM=$(grep 'CURRENT_PROJECT_VERSION = ' "$PROJECT/project.pbxproj" | head -1 | grep -o '[0-9][0-9]*')
NEXT_BUILD=$((BUILD_NUM + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION = ${BUILD_NUM};/CURRENT_PROJECT_VERSION = ${NEXT_BUILD};/g" \
    "$PROJECT/project.pbxproj"
ok "Build number ${BUILD_NUM} → ${NEXT_BUILD} (commit deferred until after notarization)"

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
# If notarization fails, revert the version-number changes so the working tree
# is clean and no stranded "Bump version" commit is left on the branch.
if ! xcrun notarytool submit "$DMG" --wait --keychain-profile "WoWoNotary"; then
    git checkout -- "$PROJECT/project.pbxproj"
    fail "Notarization failed — version changes in project.pbxproj have been reverted"
fi
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

# ── Commit version and build-number bump ──────────────────────────────────────
# Deferred until here so a notarization failure never strands a version-bump
# commit on the branch. Notarization succeeded above, so it is safe to commit.
step "Committing version and build number bump"
if [[ -n "$(git status --short -- "$PROJECT/project.pbxproj")" ]]; then
    git add "$PROJECT/project.pbxproj"
    git commit -m "Bump version to $VERSION"
    ok "Committed version bump ($CURRENT → $VERSION, build $BUILD_NUM → $NEXT_BUILD)"
else
    ok "project.pbxproj unchanged — nothing to commit"
fi

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

# Landing page: download button URLs and button text.
sed -i '' "s|WaxOnWaxOff-v[0-9][0-9.]*\.dmg|WaxOnWaxOff-${TAG}.dmg|g" "$LANDING_IDX"
sed -i '' "s|>Download v[0-9][0-9.]*<|>Download ${TAG}<|g" "$LANDING_IDX"

# Sanity-check: nothing should still reference the old version.
if grep -E "WaxOnWaxOff-v[0-9]+\.[0-9]+\.[0-9]+\.dmg" "$MANUAL_IDX" "$LANDING_IDX" "$PROJECT_DIR/README.md" \
        | grep -v "${TAG}\.dmg" >/dev/null; then
    fail "Stale version references remain after rewrite — check sed patterns"
fi

if [[ -n "$(git status --porcelain)" ]]; then
    git add "$MANUAL_IDX" "$LANDING_IDX" "$PROJECT_DIR/README.md"
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
# A curated description at release-notes/v<version>.md wins over the generated
# commit list. Use it when the release needs prose the log can't produce —
# licensing notes, a known-gap disclosure, an explanation of what changed and
# what deliberately didn't. Without one, fall back to subjects since the last tag.
NOTES_FILE="$PROJECT_DIR/release-notes/${TAG}.md"
if [[ -f "$NOTES_FILE" ]]; then
    ok "Using curated notes: release-notes/${TAG}.md"
    gh release create "$TAG" "$DMG" \
        --repo "$REPO" \
        --title "WaxOn/WaxOff $TAG" \
        --notes-file "$NOTES_FILE"
else
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
fi
ok "Release published"

# ── Remove old app releases (keep the ${KEEP_RELEASES} most recent v* tags) ───
# Never delete ffmpeg-deps-* — CI and fresh clones download binaries from that
# release (see scripts/fetch-ffmpeg.sh). Pruning all releases by date removed
# ffmpeg-deps-8.0-arm64 during the v2.0.6 cut.
#
# Raised 5 → 10 for the 2.4.0 cut. Every release through v2.3.0 bundles the
# third-party GPL FFmpeg build, so those pages carry GPL Corresponding Source
# obligations. Deleting a page does not end the obligation — it attaches to
# distributions already made, and everyone who downloaded keeps their
# entitlement — it only removes our means of satisfying it. At 5 this step
# would have deleted v2.2.1 in the same run that adds source directions to the
# others. Retention of GPL-bearing releases is a licensing decision (#12), not
# something a tail -n +N should make mid-publish.
KEEP_RELEASES=10
step "Removing old app releases (keeping ${KEEP_RELEASES} most recent v* tags)"
OLD_TAGS=$(gh release list --repo "$REPO" --limit 100 --json tagName \
    --jq '.[].tagName' | grep -E '^v[0-9]' | tail -n +$((KEEP_RELEASES + 1)) || true)
if [[ -z "$OLD_TAGS" ]]; then
    ok "No old app releases to remove"
else
    while IFS= read -r old_tag; do
        case "$old_tag" in
            ffmpeg-deps-*)
                ok "Skipped protected deps release $old_tag"
                continue
                ;;
        esac
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
