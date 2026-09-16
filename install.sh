#!/usr/bin/env bash
set -euo pipefail

readonly SERVICE='v4l2-relayd@default.service'
readonly RELAY_CONFIG='/etc/v4l2-relayd.d/default.conf'
readonly STATE_DIR='/var/lib/cameranoise'
readonly ORIGINAL_CONFIG="$STATE_DIR/default.conf.before-install"
readonly INSTALLED_CONFIG_SHA="$STATE_DIR/default.conf.installed.sha256"
readonly ENV_FILE='/etc/default/cameranoise'
readonly DROPIN_DIR='/etc/systemd/system/v4l2-relayd@default.service.d'
readonly DROPIN="$DROPIN_DIR/30-cameranoise.conf"
readonly INSTALLED_LIBRARY='/usr/local/lib/cameranoise/libcameranoise.so'
readonly INSTALLED_COMMAND='/usr/local/bin/cameranoise'
readonly SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

usage() {
    cat <<EOF
Usage: ${0##*/} [STRENGTH]

Install ipu6-nr-control and select the initial HAL noise-reduction strength.
STRENGTH may be any multiple of 10 from -100 through 100. The default is -60.
Close all camera applications before installation.
EOF
}

normalize_strength() {
    case ${1-} in
        -100|-90|-80|-70|-60|-50|-40|-30|-20|-10|\
        0|10|20|30|40|50|60|70|80|90|100)
            printf '%s\n' "$1"
            ;;
        +10|+20|+30|+40|+50|+60|+70|+80|+90|+100)
            printf '%s\n' "${1#+}"
            ;;
        *) return 1 ;;
    esac
}

case ${1-} in
    -h|--help)
        usage
        exit 0
        ;;
esac

if [[ $# -gt 1 ]]; then
    usage >&2
    exit 2
fi

if ! strength=$(normalize_strength "${1:--60}"); then
    printf 'Unsupported strength: %s\n' "${1-}" >&2
    usage >&2
    exit 2
fi

if [[ $EUID -ne 0 ]]; then
    exec sudo -- "$0" "$strength"
fi

for command in g++ readelf install awk sha256sum systemctl mktemp; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'Required command is missing: %s\n' "$command" >&2
        exit 1
    fi
done

if [[ ! -f $RELAY_CONFIG ]]; then
    printf 'Relay configuration not found: %s\n' "$RELAY_CONFIG" >&2
    exit 1
fi

temporary_dir=$(mktemp -d /tmp/cameranoise-install.XXXXXX)
rollback_required=false

cleanup() {
    rm -rf -- "$temporary_dir"
}

rollback() {
    local rc=$?
    trap - ERR INT TERM

    if $rollback_required; then
        printf 'Installation failed; restoring the previous camera setup.\n' >&2
        systemctl stop "$SERVICE" 2>/dev/null || true
        install -o root -g root -m 0644 -- \
            "$temporary_dir/relay-config.previous" "$RELAY_CONFIG" || true

        if [[ -f $temporary_dir/dropin.previous ]]; then
            install -o root -g root -m 0644 -- \
                "$temporary_dir/dropin.previous" "$DROPIN" || true
        else
            unlink -- "$DROPIN" 2>/dev/null || true
        fi

        if [[ -f $temporary_dir/environment.previous ]]; then
            install -o root -g root -m 0644 -- \
                "$temporary_dir/environment.previous" "$ENV_FILE" || true
        else
            unlink -- "$ENV_FILE" 2>/dev/null || true
        fi

        if [[ -f $temporary_dir/library.previous ]]; then
            install -o root -g root -m 0755 -- \
                "$temporary_dir/library.previous" "$INSTALLED_LIBRARY" || true
        else
            unlink -- "$INSTALLED_LIBRARY" 2>/dev/null || true
        fi

        if [[ -f $temporary_dir/command.previous ]]; then
            install -o root -g root -m 0755 -- \
                "$temporary_dir/command.previous" "$INSTALLED_COMMAND" || true
        else
            unlink -- "$INSTALLED_COMMAND" 2>/dev/null || true
        fi

        if [[ -f $temporary_dir/installed-config-sha.previous ]]; then
            install -o root -g root -m 0644 -- \
                "$temporary_dir/installed-config-sha.previous" \
                "$INSTALLED_CONFIG_SHA" || true
        else
            unlink -- "$INSTALLED_CONFIG_SHA" 2>/dev/null || true
        fi

        systemctl daemon-reload || true
        systemctl reset-failed "$SERVICE" || true
        systemctl start "$SERVICE" || true
    fi

    cleanup
    exit "$rc"
}

trap cleanup EXIT
trap rollback ERR INT TERM

g++ -std=c++17 -shared -fPIC -O2 -Wall -Wextra -Werror \
    -Wl,-z,now \
    -o "$temporary_dir/libcameranoise.so" \
    "$SCRIPT_DIR/src/cameranoise.cpp" \
    -Wl,--no-as-needed -l:libcamhal.so.0 -Wl,--as-needed

if ! readelf -d "$temporary_dir/libcameranoise.so" |
     grep -q 'NEEDED.*libcamhal.so.0'; then
    printf 'Built library is not linked to libcamhal.so.0.\n' >&2
    exit 1
fi

if ! readelf -d "$temporary_dir/libcameranoise.so" |
     grep -q 'FLAGS.*BIND_NOW'; then
    printf 'Built library does not use immediate symbol binding.\n' >&2
    exit 1
fi

awk '
    /^VIDEOSRC=/ {
        line = $0
        gsub(/[[:space:]]+wdr-level=[^[:space:]]+/, "", line)
        print line " wdr-level=0"
        found = 1
        next
    }
    { print }
    END { if (!found) exit 42 }
' "$RELAY_CONFIG" >"$temporary_dir/relay-config.new"

printf 'CAMERANOISE_STRENGTH=%s\n' "$strength" >"$temporary_dir/environment.new"

cp -a -- "$RELAY_CONFIG" "$temporary_dir/relay-config.previous"
[[ ! -f $DROPIN ]] || cp -a -- "$DROPIN" "$temporary_dir/dropin.previous"
[[ ! -f $ENV_FILE ]] || cp -a -- "$ENV_FILE" "$temporary_dir/environment.previous"
[[ ! -f $INSTALLED_LIBRARY ]] || cp -a -- "$INSTALLED_LIBRARY" "$temporary_dir/library.previous"
[[ ! -f $INSTALLED_COMMAND ]] || cp -a -- "$INSTALLED_COMMAND" "$temporary_dir/command.previous"
[[ ! -f $INSTALLED_CONFIG_SHA ]] || \
    cp -a -- "$INSTALLED_CONFIG_SHA" "$temporary_dir/installed-config-sha.previous"

install -d -o root -g root -m 0755 -- \
    "$STATE_DIR" \
    "$DROPIN_DIR" \
    /usr/local/lib/cameranoise \
    /usr/local/bin

if [[ ! -f $ORIGINAL_CONFIG ]]; then
    install -o root -g root -m 0644 -- "$RELAY_CONFIG" "$ORIGINAL_CONFIG"
fi

rollback_required=true

install -o root -g root -m 0755 -- \
    "$temporary_dir/libcameranoise.so" "$INSTALLED_LIBRARY"
install -o root -g root -m 0755 -- \
    "$SCRIPT_DIR/bin/cameranoise" "$INSTALLED_COMMAND"
install -o root -g root -m 0644 -- \
    "$SCRIPT_DIR/systemd/30-cameranoise.conf" "$DROPIN"
install -o root -g root -m 0644 -- \
    "$temporary_dir/environment.new" "$ENV_FILE"
install -o root -g root -m 0644 -- \
    "$temporary_dir/relay-config.new" "$RELAY_CONFIG"

sha256sum "$RELAY_CONFIG" | awk '{print $1}' >"$INSTALLED_CONFIG_SHA"
chmod 0644 "$INSTALLED_CONFIG_SHA"

systemctl daemon-reload
systemctl reset-failed "$SERVICE"
systemctl restart "$SERVICE"
systemctl is-active --quiet "$SERVICE"

rollback_required=false

printf 'ipu6-nr-control installed successfully; command: cameranoise\n'
printf 'Configured HAL NR strength: %s\n' "$strength"
printf 'Relay state: active\n'
printf '\nChange it later with any 10-point step from -100 through 100.\n'
