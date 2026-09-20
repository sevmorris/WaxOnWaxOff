#!/usr/bin/env zsh
# release.sh — Build, verify, package, and publish a WaxOn/WaxOff release.
#
# Usage: ./release.sh <version> [--allow-red-ci] [--generated-notes]
#   e.g. ./release.sh 1.2.0
#
# Requires: xcodebuild, hdiutil, gh (GitHub CLI), git

set -euo pipefail

REPO="sevmorris/WaxOnWaxOff"

# notarytool keychain profile, shared by every sibling release script. A profile
# cannot be exported, so a new Mac needs it created again under this name:
#   xcrun notarytool store-credentials notarytool --apple-id <email> --team-id T9RLNAXPWU
# Set NOTARY_PROFILE to use another (a Mac still holding the old WoWoNotary one).
NOTARY_PROFILE="${NOTARY_PROFILE:-notarytool}"

# ── Args ──────────────────────────────────────────────────────────────────────
# One positional argument (the version) plus optional flags in any position.
# Anything else — including no arguments, or a second positional that isn't a
# flag — still fails with usage, as it did before the flags existed.
ALLOW_RED_CI=0
ALLOW_GENERATED_NOTES=0
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --allow-red-ci)    ALLOW_RED_CI=1 ;;
        --generated-notes) ALLOW_GENERATED_NOTES=1 ;;
        *)                 ARGS+=("$arg") ;;
    esac
done

if [[ ${#ARGS[@]} -ne 1 ]]; then
    echo "Usage: $0 <version> [--allow-red-ci] [--generated-notes]"
    echo "  e.g. $0 1.2.0"
    echo ""
    echo "  --allow-red-ci     Release even when CI is not green for HEAD."
    echo "  --generated-notes  Release without a curated release-notes file,"
    echo "                     generating notes from commit subjects instead."
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
DMG="/tmp/WaxOnWaxOff-${TAG}.dmg"
APP_ZIP="/tmp/WaxOnWaxOff-${TAG}-app.zip"
MOUNT="/tmp/waxon_verify_${VERSION}"
MANUAL_IDX="$PROJECT_DIR/docs/manual/index.html"
LANDING_IDX="$PROJECT_DIR/docs/index.html"
NOTES_FILE="$PROJECT_DIR/release-notes/${TAG}.md"

# Set once project.pbxproj has been rewritten in place and cleared once that
# rewrite is committed. While it is 1 the working tree carries an uncommitted
# version bump, and the EXIT trap reverts it.
BUMP_ACTIVE=0

# Same contract for the docs rewrite: set once the README, manual and landing
# page are being rewritten in place and cleared once that rewrite is committed.
# A separate flag because the two windows are disjoint — the version bump is
# already committed before the first docs sed runs — and because they revert
# different files.
DOCS_ACTIVE=0

# ── Helpers ───────────────────────────────────────────────────────────────────
step()  { echo "\n▶ $*"; }
ok()    { echo "  ✓ $*"; }
fail()  { echo "\n  ✗ $*" >&2; exit 1; }
warn()  { echo "  ! $*" >&2; }

cleanup() {
    # Uses ${VAR:-} so the trap fires cleanly even if the script exits before
    # the path variables are defined (e.g. early exit on argument-error). A bare
    # (( BUMP_ACTIVE )) would trip `set -u` on those early exits, hence the :-0.
    #
    # The version bump is written to project.pbxproj long before it is committed,
    # so any failure in that window would otherwise leave the bump stranded in the
    # working tree — and the dirty-tree preflight then blocks the next run until
    # someone reverts it by hand. Reverting the whole file is safe precisely
    # because preflight proved the tree clean at entry: the script's own two seds
    # are the only changes present, so there is nothing else here to discard.
    if (( ${BUMP_ACTIVE:-0} )); then
        git -C "${PROJECT_DIR:-.}" checkout -- "${PROJECT:-}/project.pbxproj" 2>/dev/null || true
    fi
    # Same reasoning for the docs rewrite, one window later. These three paths
    # are exactly the ones the `git add` below stages, so a failure between the
    # first sed and that commit restores the same set it would have committed.
    if (( ${DOCS_ACTIVE:-0} )); then
        git -C "${PROJECT_DIR:-.}" checkout -- \
            "${MANUAL_IDX:-}" "${LANDING_IDX:-}" "${PROJECT_DIR:-.}/README.md" 2>/dev/null || true
    fi
    # A failure between attach and detach leaves the image mounted there.
    if [[ -d "${MOUNT:-}" ]]; then
        hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
        rm -rf -- "$MOUNT" || true
    fi
    [[ -d "${DERIVED_DATA:-}" ]] && rm -rf -- "$DERIVED_DATA" || true
    [[ -f "${DMG:-}" ]]          && rm -f  -- "$DMG"          || true
    [[ -f "${APP_ZIP:-}" ]]      && rm -f  -- "$APP_ZIP"      || true
}
# A zsh EXIT trap does not fire on a signal, so Ctrl-C or a closed terminal
# during the long notarization wait used to leave the version bump sitting in
# the working tree — the same stranded-bump state that blocked two releases on
# 2026-09-16, which the deferred commit only fixed for an ordinary failure.
# These handlers exit and let the EXIT trap do the cleanup, exactly once.
trap 'exit 130' INT
trap 'exit 143' TERM
trap cleanup EXIT

# ── Preflight ─────────────────────────────────────────────────────────────────
step "Preflight checks"
for cmd in xcodebuild hdiutil gh git codesign xcrun curl python3; do
    command -v $cmd &>/dev/null || fail "'$cmd' not found in PATH"
done
python3 -c "import dmgbuild" 2>/dev/null \
    || fail "python3 module 'dmgbuild' not installed — run: python3 -m pip install dmgbuild"
# Importing dmgbuild does not prove it can run. On 2026-09-16 a pyenv Python
# built against Xcode 27's macOS 27 SDK, on macOS 26.7, imported it and then
# segfaulted on its first subprocess — dmgbuild's hdiutil call — and every DMG
# that day went out without its installer window.
python3 -c "import subprocess; subprocess.run(['/usr/bin/true'], check=True)" &>/dev/null \
    || fail "$(command -v python3) cannot start a subprocess, so dmgbuild would crash — rebuild that Python against an SDK no newer than this macOS"
ok "Tools present"

# A missing profile used to surface at the notarization step, after a clean
# build — which is how a new Mac found out. Asking costs one API call.
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" &>/dev/null \
    || fail "notarytool profile '$NOTARY_PROFILE' is missing, rejected or unreachable — create it with: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <email> --team-id T9RLNAXPWU"
ok "notarytool profile '$NOTARY_PROFILE' works"

cd "$PROJECT_DIR"

if [[ -n "$(git status --porcelain)" ]]; then
    fail "Working tree is dirty — commit or stash changes before releasing"
fi
ok "Working tree clean"

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

# The remote's tags are the record, not this clone's. A clone that has not seen
# a release — made on another Mac, or one whose tag push failed — passes a
# local-only check, then builds, notarizes and pushes the branch before the tag
# is refused. On 2026-09-16 that left v2.12.1's re-run commit on main with no
# tag, and a local v2.12.1 that disagreed with the published one. Fetching first
# lets the checks below see every published tag, and a local tag that disagrees
# with the remote makes the fetch itself fail.
git fetch --tags "$REMOTE" \
    || fail "Could not fetch tags from $REMOTE — a tag reported as rejected above points at different commits here and on $REMOTE"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    fail "Tag $TAG already exists — has this version been released?"
fi
ok "Tag $TAG is available"

# The push at the end is a fast-forward or nothing, so a remote branch with
# commits this one lacks would fail it after the notarization. Stop now instead.
if git rev-parse -q --verify "refs/remotes/$REMOTE/$BRANCH" >/dev/null \
        && ! git merge-base --is-ancestor "$REMOTE/$BRANCH" HEAD; then
    fail "$REMOTE/$BRANCH has commits that HEAD lacks — pull before releasing"
fi
ok "HEAD contains everything on $REMOTE/$BRANCH"

# ── Version ordering ────────────────────────────────────────────────────────────────────────
# Nothing here stopped a release going backwards. On 2026-09-03 Magic Backup
# Machine published v1.3.9 on top of v1.4.2 — two sessions releasing from one
# clone, neither aware of the other. GitHub served the older build as "latest"
# from that moment, and because the update checker compares numerically, every
# client already on 1.4.2 read 1.3.9 as older and reported itself up to date.
# The release could not reach anyone.
#
# Tags are the record of what is actually published, and what "latest" keys on,
# so they are what this compares against. Set ALLOW_DOWNGRADE=1 to override.
step "Checking version ordering"
version_core() { printf '%s' "${1%%[-+]*}"; }
HIGHEST_TAG=$(git tag --list 'v[0-9]*' --sort=-v:refname | head -1 | sed 's/^v//')
if [[ -n "$HIGHEST_TAG" ]]; then
    NEW_CORE=$(version_core "$VERSION")
    REF_CORE=$(version_core "$HIGHEST_TAG")
    # Numeric cores only: `sort -V` places 1.7.0 ahead of 1.7.0-rc.1, backwards
    # from semver, and comparing raw strings would block any release that
    # follows its own release candidate.
    if [[ "$NEW_CORE" != "$REF_CORE" ]] \
       && [[ "$(printf '%s\n%s\n' "$NEW_CORE" "$REF_CORE" | sort -V | head -1)" == "$NEW_CORE" ]]; then
        if [[ "${ALLOW_DOWNGRADE:-0}" != "0" ]]; then
            warn "$VERSION sorts below tag v$HIGHEST_TAG — continuing, ALLOW_DOWNGRADE is set"
        else
            fail "$VERSION sorts below the highest tag v$HIGHEST_TAG. Publishing it would leave GitHub serving an older build as 'latest', and clients on $HIGHEST_TAG would be told they are up to date. Set ALLOW_DOWNGRADE=1 to override."
        fi
    fi
fi
ok "Version $VERSION does not go backwards"


# ── Shared-file gate ──────────────────────────────────────────────────────────
# Several files here are vendored copies kept byte-identical with the sibling
# app repos — these projects are deliberately independent, so there is no shared
# package to depend on. The failure mode that costs something is silent drift: a
# fix lands in one repo and the others keep the bug, which is exactly how the
# FFmpeg process hardening reached WaxOnWaxOff and left two latent crashes in
# ClipHack. Release day is when someone is looking, so it is when to say so.
#
# Absent siblings are not drift — a fresh clone or a CI checkout has none, and
# the check passes quietly. Only a content mismatch stops the release.
step "Checking shared files against sibling repos"
"$PROJECT_DIR/scripts/check-shared.sh" \
    || fail "Shared files have drifted from the sibling repos — reconcile them before releasing"
ok "Shared files in sync"

# ── Release-notes gate ────────────────────────────────────────────────────────
# The notes are read much later, at the GitHub-release step — by which point the
# branch and the tag have both been pushed. Failing there would strand a pushed
# tag with no release behind it, so the absence has to be caught here, while
# nothing has been mutated and nothing has left the machine.
#
# Without this, a forgotten notes file is invisible: the curated path announces
# itself, the generated path says nothing, and both end on the same "Release
# published" line. Shipping auto-generated notes becomes a silent default rather
# than a decision.
if [[ -f "$NOTES_FILE" ]]; then
    ok "Curated notes present: release-notes/${TAG}.md"
elif (( ALLOW_GENERATED_NOTES )); then
    echo "\n  ⚠ --generated-notes — publishing $TAG without curated notes" >&2
    echo "      expected:  release-notes/${TAG}.md" >&2
    echo "      notes will be generated from commit subjects since the last tag" >&2
    ok "Generated notes accepted"
else
    echo "      expected:  release-notes/${TAG}.md" >&2
    fail "No curated notes for $TAG — write that file, or re-run with --generated-notes"
fi

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
    # No MARKETING_VERSION rewrite needed, but the build-number sed below still
    # mutates project.pbxproj, so the window opens here too.
    BUMP_ACTIVE=1
    ok "Already at $VERSION"
else
    # Escape dots (and other regex metacharacters) so pre-release versions like
    # "1.7.0-rc.1" don't cause sed pattern mismatches.
    ESC_CURRENT=$(printf '%s' "$CURRENT" | sed 's/[.[\*^$]/\\&/g')
    ESC_VERSION=$(printf '%s'  "$VERSION" | sed 's/[.[\*^$]/\\&/g')
    # Arm before the first mutation, not after the last. Between the two seds
    # sits a grep pipeline that reads the build number; under `set -o pipefail`
    # it can abort with this sed's edit already on disk, so arming afterwards
    # would leave exactly the stranded bump this flag exists to prevent.
    BUMP_ACTIVE=1
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
# -destination 'generic/platform=macOS' ("Any Mac"): without it xcodebuild picks
# the first matching run destination, warns about it on every release, and builds
# for that destination's arch alone. With it, ARCHS decides — arm64, the only
# arch the bundled FFmpeg has.
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -destination 'generic/platform=macOS' \
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

# ── Notarize app ──────────────────────────────────────────────────────────────
step "Notarizing app"
# Stapling the DMG alone leaves the app unstapled once it is dragged out, which
# is the only form anyone actually runs. Gatekeeper still passes it — it falls
# back to asking Apple — but that needs a working network on first launch. So
# the app gets its own notarization round trip and its own ticket here, before
# the DMG is built around it; the DMG is then stapled separately below.
#
# The ticket covers this exact cdhash, so this has to run after codesigning and
# before the app is copied into the DMG.
rm -f "$APP_ZIP"
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" --wait --keychain-profile "$NOTARY_PROFILE" \
    || fail "App notarization failed"
xcrun stapler staple "$APP_PATH" || fail "Stapling the app failed"
xcrun stapler validate "$APP_PATH" >/dev/null || fail "App has no valid stapled ticket"
rm -f "$APP_ZIP"
ok "App notarized and stapled"

# ── Stage DMG contents ────────────────────────────────────────────────────────
# ── Create DMG ────────────────────────────────────────────────────────────────
# Built with dmgbuild rather than bare hdiutil so the installer window is laid
# out: background art with an arrow, the app and the Applications alias pinned
# to its endpoints, chrome hidden. dmgbuild writes the .DS_Store directly, so
# this needs no Finder, no GUI session and no automation permission — styling a
# mounted image with AppleScript would make releases fail for environment
# reasons rather than code ones.
#
# Two PATH subtleties, both load-bearing:
#   * python3 is resolved BEFORE the PATH override, so we keep the interpreter
#     that actually has dmgbuild installed rather than Xcode's bundled one.
#   * /bin is prepended for the child, because dmgbuild shells out to bare
#     `sync` and a personal ~/bin/sync would otherwise shadow the system one
#     and abort the build.
#
# There is no fallback to bare hdiutil, deliberately. One was added on
# 2026-09-16 for what looked like dmgbuild crashing on a new Mac; the crash was
# the Python interpreter (see preflight), and the fallback shipped that day's
# DMGs without their installer window while still reporting a styled one.
# A DMG without its window is a failed release, not a degraded one.
step "Creating DMG"
rm -f "$DMG"
DMG_BACKGROUND="$PROJECT_DIR/tools/dmg/dmg-background-waxonwaxoff.png"
[[ -f "$DMG_BACKGROUND" ]] \
    || fail "Missing DMG background: ${DMG_BACKGROUND#$PROJECT_DIR/} — regenerate with tools/dmg/make-background.py"
PY_BIN=$(command -v python3)
PATH="/bin:/usr/bin:$PATH" "$PY_BIN" -m dmgbuild \
    -s "$PROJECT_DIR/tools/dmg/dmg-settings.py" \
    -D app="$APP_PATH" \
    -D background="$DMG_BACKGROUND" \
    "Install WaxOnWaxOff" \
    "$DMG" >/dev/null \
    || fail "dmgbuild failed (exit $?) — no DMG was built"
[[ -f "$DMG" ]] || fail "dmgbuild did not produce $DMG"
ok "Created $(du -sh $DMG | cut -f1) styled DMG"

# ── Notarize ──────────────────────────────────────────────────────────────────
step "Notarizing DMG"
# NOTARY_PROFILE is defined at the top and proven usable in preflight.
# The version-number changes are reverted by the EXIT trap, which owns that job
# for every failure in the window, not just this one.

# The image itself is signed, not only the app inside it. An unsigned DMG
# reports "no usable signature" to spctl even with a valid ticket stapled, so
# the wrapper can never be assessed — a download that looks unsigned to
# Gatekeeper while the app within it is perfectly notarized. Signing has to
# precede submission; stapling afterwards leaves the signature intact.
codesign --force --timestamp --sign "$IDENTITY" "$DMG" \
    || fail "Signing the DMG failed"

if ! xcrun notarytool submit "$DMG" --wait --keychain-profile "$NOTARY_PROFILE"; then
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
# Check the ticket on the copy that actually ships, not on the build product
# we stapled — those are the two that can drift apart. Captured before the
# detach so the volume is never left mounted on a failure.
if xcrun stapler validate "$MOUNT/WaxOnWaxOff.app" >/dev/null 2>&1; then
    DMG_APP_STAPLED=1
else
    DMG_APP_STAPLED=0
fi
# The installer window is these two files: the .DS_Store carrying the layout and
# the background art it points at. Without them the image opens as a plain folder.
DMG_DSSTORE=( "$MOUNT"/.DS_Store(N) )
DMG_BGART=( "$MOUNT"/.background.*(N) )
hdiutil detach "$MOUNT" -quiet
[[ "$DMG_APP_STAPLED" == 1 ]] || \
    fail "App inside the DMG carries no notarization ticket"
[[ "$DMG_VERSION" == "$VERSION" ]] || \
    fail "DMG version mismatch: expected $VERSION, got $DMG_VERSION"
(( ${#DMG_DSSTORE} && ${#DMG_BGART} )) || \
    fail "DMG has no installer window layout (.DS_Store and .background.* are not both present)"
ok "DMG contains $DMG_VERSION, with its installer window layout"

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
# Disarm: the bump is committed (or there was nothing to commit), so the working
# tree no longer carries it and the trap must not revert on a successful exit.
# Placed after the `fi` so a failing `git add`/`git commit` still leaves the trap
# armed — those exit with the bump uncommitted, which is exactly the case it
# exists for.
BUMP_ACTIVE=0

# ── Update docs (README + manual) to point at the new version ────────────────
# Per project convention: rewrite unconditionally and let `git status --porcelain`
# decide whether anything actually changed before committing.
step "Updating docs to ${TAG}"

# Armed before the first of the eight seds below. Arming after any one of them
# would strand the edits the earlier ones already made; arming here is a no-op
# if the script exits before anything is written.
DOCS_ACTIVE=1

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
# Disarm: the rewrite is committed (or there was nothing to commit). Placed
# after the `fi` so a failing `git add`/`git commit` still leaves the trap
# armed — those exit with the rewrite uncommitted, which is the case it exists
# for.
DOCS_ACTIVE=0

# ── Tag and push ──────────────────────────────────────────────────────────────
step "Tagging and pushing"
git tag "$TAG"
# REMOTE and BRANCH were resolved in preflight. One atomic push: the branch and
# the tag land together or not at all. As two pushes, a refused tag left the
# release commit on the branch with nothing tagging it. On failure nothing has
# been published, so the tag made just above is removed and a re-run starts clean.
if ! git push --atomic -u "$REMOTE" "HEAD:refs/heads/$BRANCH" "refs/tags/$TAG"; then
    git tag -d "$TAG" >/dev/null
    fail "Push to $REMOTE failed and nothing was published — the local $TAG tag has been removed"
fi
ok "Pushed $TAG to $REMOTE/$BRANCH"

# ── GitHub release ────────────────────────────────────────────────────────────
step "Creating GitHub release"
# A curated description at release-notes/v<version>.md wins over the generated
# commit list. Use it when the release needs prose the log can't produce —
# licensing notes, a known-gap disclosure, an explanation of what changed and
# what deliberately didn't. Without one, fall back to subjects since the last tag.
#
# NOTES_FILE is defined with the other paths and its absence is gated in
# preflight, so reaching the generated branch here means --generated-notes was
# passed deliberately.
if [[ -f "$NOTES_FILE" ]]; then
    ok "Using curated notes: release-notes/${TAG}.md"
    gh release create "$TAG" "$DMG" \
        --repo "$REPO" \
        --title "WaxOn/WaxOff $TAG" \
        --notes-file "$NOTES_FILE"
else
    # App tags only: the ffmpeg-deps-* tags are cut at main's head whenever a
    # deps build is published, and one newer than the last release would
    # silently shorten these notes.
    PREV_TAG=$(git tag --list 'v[0-9]*' --sort=-creatordate | grep -v "^${TAG}$" | head -1 || true)
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

# ── Remove old app release PAGES (keep the ${KEEP_RELEASES} most recent) ─────
# This prunes the GitHub release page and its DMG asset. It does NOT touch the
# git tag, locally or on the remote — deliberately. The tag is the only durable
# pointer to what shipped: without it a version is both unbuildable from a clean
# clone and unreachable from its own CHANGELOG entry, and restoring one after
# the fact means recovering the commit SHA from somewhere else. A release page
# is a convenience; a tag is the record. This is what CHANGELOG.md already
# describes — "older versions are reachable by tag but their release pages have
# been pruned" — which until now the `--cleanup-tag` on the delete below made
# false.
#
# Ten is chosen to cover roughly a year of releases at the current cadence, so
# the download links in recent CHANGELOG entries and in any circulating issue
# thread keep resolving. It is not a licensing constraint: the GPL-bearing
# artifacts that once made retention a compliance question have been withdrawn
# from distribution entirely (see Vendor/README.md, "Historical builds").
KEEP_RELEASES=10
step "Removing old app release pages (keeping ${KEEP_RELEASES} most recent v* releases)"
OLD_TAGS=$(gh release list --repo "$REPO" --limit 100 --json tagName \
    --jq '.[].tagName' | grep -E '^v[0-9]' | tail -n +$((KEEP_RELEASES + 1)) || true)
if [[ -z "$OLD_TAGS" ]]; then
    ok "No old app release pages to remove"
else
    while IFS= read -r old_tag; do
        # What actually keeps ffmpeg-deps-* out of this loop is the
        # `grep -E '^v[0-9]'` filter above: the deps tag begins with "f", so it
        # never reaches here. This case is a backstop only, kept in case that
        # filter is ever loosened. CI and fresh clones download binaries from
        # that release (see scripts/fetch-ffmpeg.sh), and pruning by date alone
        # removed ffmpeg-deps-8.0-arm64 during the v2.0.6 cut.
        case "$old_tag" in
            ffmpeg-deps-*)
                ok "Skipped protected deps release $old_tag"
                continue
                ;;
        esac
        gh release delete "$old_tag" --repo "$REPO" --yes 2>/dev/null || true
        ok "Pruned release page for $old_tag (tag kept)"
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
rm -rf "$MOUNT" "$DERIVED_DATA"
rm -f "$DMG"
ok "Temp files removed"

# ── Open release page ─────────────────────────────────────────────────────────
RELEASE_URL="https://github.com/${REPO}/releases/tag/${TAG}"
echo "\n✓ WaxOn/WaxOff $TAG released successfully."
echo "  $RELEASE_URL"
open "$RELEASE_URL"
