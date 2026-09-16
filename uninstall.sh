#!/usr/bin/env bash
set -euo pipefail

readonly SERVICE='v4l2-relayd@default.service'
readonly RELAY_CONFIG='/etc/v4l2-relayd.d/default.conf'
readonly STATE_DIR='/var/lib/cameranoise'
readonly ORIGINAL_CONFIG="$STATE_DIR/default.conf.before-install"
readonly INSTALLED_CONFIG_SHA="$STATE_DIR/default.conf.installed.sha256"
readonly ENV_FILE='/etc/default/cameranoise'
readonly DROPIN='/etc/systemd/system/v4l2-relayd@default.service.d/30-cameranoise.conf'
readonly INSTALLED_LIBRARY='/usr/local/lib/cameranoise/libcameranoise.so'
readonly INSTALLED_COMMAND='/usr/local/bin/cameranoise'

usage() {
    cat <<EOF
Usage: ${0##*/} [--force]

Remove ipu6-nr-control and restore the relay configuration saved at installation.
Use --force only if the relay configuration was deliberately edited afterward.
Close all camera applications first.
EOF
}

case ${1-} in
    -h|--help)
        usage
        exit 0
        ;;
    ''|--force) ;;
    *)
        usage >&2
        exit 2
        ;;
esac

force=false
[[ ${1-} != --force ]] || force=true

if [[ $EUID -ne 0 ]]; then
    exec sudo -- "$0" "${1-}"
fi

if [[ ! -f $ORIGINAL_CONFIG ]]; then
    printf 'Original relay configuration backup is missing: %s\n' "$ORIGINAL_CONFIG" >&2
    exit 1
fi

if [[ -f $INSTALLED_CONFIG_SHA && -f $RELAY_CONFIG ]]; then
    expected_sha=$(<"$INSTALLED_CONFIG_SHA")
    current_sha=$(sha256sum "$RELAY_CONFIG" | awk '{print $1}')
    if [[ $current_sha != "$expected_sha" ]] && ! $force; then
        printf 'Refusing to overwrite a relay configuration changed after installation.\n' >&2
        printf 'Review it first, or rerun with --force.\n' >&2
        exit 1
    fi
fi

systemctl stop "$SERVICE"
install -o root -g root -m 0644 -- "$ORIGINAL_CONFIG" "$RELAY_CONFIG"
unlink -- "$DROPIN" 2>/dev/null || true
unlink -- "$ENV_FILE" 2>/dev/null || true
unlink -- "$INSTALLED_LIBRARY" 2>/dev/null || true
unlink -- "$INSTALLED_COMMAND" 2>/dev/null || true
systemctl daemon-reload
systemctl reset-failed "$SERVICE"
systemctl start "$SERVICE"
systemctl is-active --quiet "$SERVICE"

printf 'ipu6-nr-control removed; the pre-install relay configuration is restored.\n'
printf 'The safety backup remains in %s.\n' "$STATE_DIR"
