#!/usr/bin/env bash
# Build a release .kwinscript bundle for distribution.
#
# Output: vibetiles.kwinscript with the canonical, non-numeric plugin ID
# "vibetiles", suitable for installing via System Settings → KWin Scripts →
# "Install from File..." or via `kpackagetool6 -t KWin/Script -i <bundle>`.
#
# The bundle ships under the canonical name so fresh installs land in the
# user's scripts list as "vibetiles" rather than the numbered dev ID. Your
# live dev install (the symlink in ~/.local/share/kwin/scripts/) is NOT
# touched - this script temporarily rewrites metadata.json for the build,
# then restores it. Working tree ends unchanged; bump.sh continues to bump
# the numbered dev ID on every subsequent main.qml edit.
#
# Does NOT consolidate the live install to "vibetiles" - that's a separate
# operation that requires a kwin_wayland restart to bust the per-plugin-ID
# compiled-QML cache, which would crash every running Wayland app. The
# numbered dev workflow keeps that restart off the table.

set -euo pipefail
cd "$(dirname "$0")"

# Current dev ID (e.g. vibetiles26); canonical ID we ship under.
DEV_ID=$(grep -oE '"vibetiles[0-9]+"' kwinscript/metadata.json | head -1 | tr -d '"')
RELEASE_ID="vibetiles"
OUT="${RELEASE_ID}.kwinscript"

if [[ ! -d kwinscript ]]; then
    echo "error: kwinscript/ not found - run from the repo root" >&2
    exit 1
fi

if [[ -z "${DEV_ID}" ]]; then
    echo "error: couldn't find a vibetiles<N> ID in kwinscript/metadata.json" >&2
    exit 1
fi

# ID swap: temporarily rewrite metadata.json to the canonical ID, build, restore.
# trap ensures restoration on any error path; explicit restore on success so the
# end state is guaranteed clean either way.
swap_to_release() {
    [[ "${DEV_ID}" == "${RELEASE_ID}" ]] && return 0
    sed -i "s/${DEV_ID}/${RELEASE_ID}/g" kwinscript/metadata.json
}
restore_dev() {
    [[ "${DEV_ID}" == "${RELEASE_ID}" ]] && return 0
    sed -i "s/${RELEASE_ID}/${DEV_ID}/g" kwinscript/metadata.json
}
trap restore_dev EXIT

swap_to_release

# Sanity: both ID fields (KPlugin.Id and X-KDE-PluginKeyword) must agree after
# the swap, otherwise kpackagetool6 silently loads nothing.
INTERNAL=$(grep -oE '"vibetiles[0-9]*"' kwinscript/metadata.json | sort -u)
if [[ $(echo "${INTERNAL}" | wc -l) -ne 1 ]]; then
    echo "error: metadata.json ID swap left mismatched ID fields:" >&2
    echo "${INTERNAL}" >&2
    exit 1
fi

# KPackage format: a zip archive with metadata.json at the archive root (no
# wrapping directory) - confirmed live that kpackagetool6 flatly refuses
# anything else ("unsupported archive format: ... application/gzip") even
# though the file has a .kwinscript extension; a gzipped tar (the previous
# approach here) was never actually installable via kpackagetool6 or System
# Settings' "Install from File...", only via manually re-packing as zip.
rm -f "${OUT}"
(cd kwinscript && zip -rq "../${OUT}" .)
SIZE=$(stat -c %s "${OUT}")

restore_dev
trap - EXIT

echo "built ${OUT} (${SIZE} bytes) with plugin ID '${RELEASE_ID}'"
echo "  (live dev install stays on ${DEV_ID}; bump.sh will keep bumping that one)"
echo
echo "install with: kpackagetool6 -t KWin/Script -i ${OUT}"
echo "or:           System Settings → KWin Scripts → Install from File..."
