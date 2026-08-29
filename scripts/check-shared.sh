#!/usr/bin/env bash
# Shared verbatim across the sibling app repos (DoublEnder, WaxOnWaxOff,
# ClipHack, FilmStrip, KeyVault). Keep the copies byte-identical:
# scripts/check-shared.sh compares them and a release preflight fails when they
# drift. Anything app-specific belongs in that repo's release.sh, not here.
#
# Reports files that are meant to be identical across the sibling repos but
# are not. These projects are deliberately independent — there is no shared
# package — so the copies are vendored, and the failure mode is silent drift:
# a fix lands in one repo and the others keep the bug. That is not
# hypothetical. The FFmpeg process hardening landed in WaxOnWaxOff and not in
# ClipHack, and two latent crashes sat there until an audit found them.
#
# Registration is by marker, not by manifest, so there is no list to forget to
# update: a file joins the set by carrying the header comment above (its own
# first line quoted below). To share a new file, copy it to the siblings with
# that header.
#
# Copies are paired by filename, not by path: the same Swift file lives under
# WaxOnWaxOff/Services in one repo and ClipHackKit/Services in the other, and
# neither layout is wrong. Two marked files sharing a basename inside one repo
# would make that pairing meaningless, so it is reported as an error.
#
# A sibling that is missing, or that does not carry a given file, is reported
# and skipped — DoublEnder has no Swift sources to share, and a fresh clone has
# no siblings at all. Only a content mismatch, or an ambiguous pairing, fails.
set -euo pipefail

MARKER="Shared verbatim across the sibling app repos"
SIBLINGS=(DoublEnder WaxOnWaxOff ClipHack FilmStrip KeyVault)

ROOT=$(git rev-parse --show-toplevel)
SELF=$(basename "$ROOT")
PARENT=$(dirname "$ROOT")

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
dim()  { printf '\033[2m%s\033[0m\n' "$*"; }

# Tracked files carrying the marker. -I keeps binaries out; the marker is only
# ever in text. --no-color because a colorized path is not a path, and this
# user's gitconfig sets color.grep=always, which color.ui cannot override. A
# read loop rather than mapfile so /bin/bash 3.2 can run this too.
SHARED=()
while IFS= read -r line; do
    [[ -n "$line" ]] && SHARED+=("$line")
done < <(git -C "$ROOT" grep --no-color -lI --fixed-strings -e "$MARKER" -- . | sort)

if [[ ${#SHARED[@]} -eq 0 ]]; then
    dim "No shared files registered in $SELF."
    exit 0
fi

drift=0
checked=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for sib in "${SIBLINGS[@]}"; do
    [[ "$sib" == "$SELF" ]] && continue
    sibroot="$PARENT/$sib"
    if [[ ! -d "$sibroot" ]]; then
        dim "  $sib not checked out — skipped"
        continue
    fi
    git -C "$sibroot" grep --no-color -lI --fixed-strings -e "$MARKER" -- . \
        | sort > "$tmp/$sib" || true

    for rel in "${SHARED[@]}"; do
        base=${rel##*/}
        # Exact basename compare via awk, so a dot in a filename is not a
        # wildcard and no escaping is needed.
        matches=$(awk -F/ -v b="$base" '$NF == b' "$tmp/$sib")
        count=$(printf '%s' "$matches" | grep -c . || true)
        if [[ "$count" -eq 0 ]]; then
            dim "  $rel — absent in $sib"
            continue
        fi
        if [[ "$count" -gt 1 ]]; then
            red "  $rel — $count files named $base are marked shared in $sib:"
            while IFS= read -r m; do dim "      $m"; done <<< "$matches"
            drift=$((drift + 1))
            continue
        fi
        checked=$((checked + 1))
        if cmp -s "$ROOT/$rel" "$sibroot/$matches"; then
            green "  $rel == $sib/$matches"
        else
            red   "  $rel != $sib/$matches"
            red   "      diff $rel $sibroot/$matches"
            drift=$((drift + 1))
        fi
    done
done

echo
if [[ $drift -gt 0 ]]; then
    red "$drift shared file(s) have drifted. Reconcile them before releasing."
    exit 1
fi
green "$checked shared file comparison(s) clean across siblings."
