#!/usr/bin/env bash
# Install VibeTiles as a KWin script.
#
# Reads the current plugin ID from kwinscript/metadata.json (the KPackage.Id /
# X-KDE-PluginKeyword fields must stay in sync), creates the symlink KWin
# expects under ~/.local/share/kwin/scripts/, enables it, and triggers a
# reconfigure. Idempotent: safe to re-run after a clean checkout.
#
# For bumping the plugin ID after a main.qml edit (which forces KWin to
# recompile its cached QML), run ./bump.sh instead - it migrates config keys
# forward to the new section without losing your settings.

set -euo pipefail

cd "$(dirname "$0")"

PLUGIN_ID=$(grep -oE '"vibetiles[0-9]+"' kwinscript/metadata.json | head -1 | tr -d '"')
SCRIPTS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/kwin/scripts"
SRC_DIR="$(pwd)/kwinscript"
DEST="${SCRIPTS_DIR}/${PLUGIN_ID}"

# Sanity-check: the package directory has to exist before kwin will load it.
if [[ ! -d "${SRC_DIR}" ]]; then
    echo "error: ${SRC_DIR} not found - run from the repo root" >&2
    exit 1
fi

# Ensure id fields in metadata.json agree (KPlugin.Id and X-KDE-PluginKeyword
# MUST match both the symlink directory name and the [Script-<id>] group in
# kwinrc - mismatches silently load no script).
INTERNAL=$(grep -oE '"vibetiles[0-9]+"' kwinscript/metadata.json | sort -u)
if [[ $(echo "${INTERNAL}" | wc -l) -ne 1 ]]; then
    echo "error: metadata.json has multiple plugin IDs - they must match:" >&2
    echo "${INTERNAL}" >&2
    exit 1
fi

mkdir -p "${SCRIPTS_DIR}"

if [[ -L "${DEST}" ]] && [[ "$(readlink -f "${DEST}")" == "${SRC_DIR}" ]]; then
    echo "symlink ${DEST} already points at ${SRC_DIR}"
else
    # Remove stale entry of the wrong kind (a directory, or a different symlink)
    # before relinking. rm without -rf: anything here is our doing.
    [[ -e "${DEST}" || -L "${DEST}" ]] && rm "${DEST}"
    ln -s "${SRC_DIR}" "${DEST}"
    echo "created symlink ${DEST} -> ${SRC_DIR}"
fi

kwriteconfig6 --file kwinrc --group Plugins --key "${PLUGIN_ID}Enabled" true
qdbus-qt6 org.kde.KWin /KWin reconfigure

cat <<EOF

VibeTiles (${PLUGIN_ID}) installed and enabled.

  - Trigger:        Meta+Alt+D (rebind in System Settings → Shortcuts)
  - Configure:      System Settings → Window Management → KWin Scripts →
                    VibeTiles → Configure...

If the overlay doesn't appear, check:
  qdbus-qt6 org.kde.KWin /Scripting org.kde.kwin.Scripting.isScriptLoaded ${PLUGIN_ID}
EOF
