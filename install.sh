#!/bin/sh
# Install sleep-inhibit from this checkout. Both installation modes run the same
# script from the same place, so nothing is copied and there is one source of
# truth.
#
#   ./install.sh              # systemd user service (recommended) + herdr plugin
#   ./install.sh --systemd    # systemd user service only
#   ./install.sh --plugin     # herdr plugin only (no systemd)
#   ./install.sh --uninstall  # remove both

set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$REPO/inhibit.sh"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="$UNIT_DIR/herdr-inhibit.service"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/herdr/plugins/config/sleep-inhibit"

do_systemd=1
do_plugin=1
do_uninstall=0

case "${1:-}" in
--systemd) do_plugin=0 ;;
--plugin) do_systemd=0 ;;
--uninstall) do_uninstall=1 ;;
'') ;;
*)
    echo "usage: install.sh [--systemd|--plugin|--uninstall]" >&2
    exit 2
    ;;
esac

herdr_bin() {
    if command -v herdr >/dev/null 2>&1; then
        command -v herdr
    elif [ -x "$HOME/.local/bin/herdr" ]; then
        printf '%s\n' "$HOME/.local/bin/herdr"
    else
        return 1
    fi
}

if [ "$do_uninstall" -eq 1 ]; then
    if [ -f "$UNIT" ]; then
        systemctl --user disable --now herdr-inhibit.service >/dev/null 2>&1 || true
        rm -f "$UNIT"
        systemctl --user daemon-reload
        echo "removed $UNIT"
    fi
    if bin=$(herdr_bin); then
        "$bin" plugin unlink sleep-inhibit >/dev/null 2>&1 || true
        echo "unlinked herdr plugin (if it was linked)"
    fi
    sh "$SCRIPT" stop >/dev/null 2>&1 || true
    echo "sleep-inhibit: uninstalled (config in $CONFIG_DIR was left in place)"
    exit 0
fi

chmod +x "$SCRIPT"

mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_DIR/config.env" ]; then
    cp "$REPO/config.env.example" "$CONFIG_DIR/config.env"
    echo "wrote default config to $CONFIG_DIR/config.env"
fi

if [ "$do_systemd" -eq 1 ]; then
    mkdir -p "$UNIT_DIR"
    sed "s|@SCRIPT@|$SCRIPT|" "$REPO/contrib/herdr-inhibit.service.in" >"$UNIT"
    systemctl --user daemon-reload
    systemctl --user enable --now herdr-inhibit.service
    echo "installed $UNIT and started herdr-inhibit.service"
fi

if [ "$do_plugin" -eq 1 ]; then
    if bin=$(herdr_bin); then
        "$bin" plugin link "$REPO" --enabled
        echo "linked herdr plugin from $REPO"
    else
        echo "herdr binary not found; skipped plugin link" >&2
    fi
fi

echo
sh "$SCRIPT" status
