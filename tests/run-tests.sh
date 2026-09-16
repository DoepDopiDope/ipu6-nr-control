#!/usr/bin/env bash
set -euo pipefail

readonly PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly LIBRARY="$PROJECT_DIR/build/libcameranoise.so"

bash -n "$PROJECT_DIR/bin/cameranoise"
bash -n "$PROJECT_DIR/install.sh"
bash -n "$PROJECT_DIR/uninstall.sh"

make -C "$PROJECT_DIR" all

readelf -d "$LIBRARY" | grep -q 'NEEDED.*libcamhal.so.0'
readelf -d "$LIBRARY" | grep -q 'FLAGS.*BIND_NOW'

"$PROJECT_DIR/bin/cameranoise" --help >/dev/null
"$PROJECT_DIR/bin/cameranoise" levels >/dev/null

for invalid in -110 110 5 invalid; do
    if "$PROJECT_DIR/bin/cameranoise" "$invalid" >/dev/null 2>&1; then
        printf 'CLI unexpectedly accepted invalid strength: %s\n' "$invalid" >&2
        exit 1
    fi
done

if [[ $EUID -ne 0 ]]; then
    mock_dir=$(mktemp -d /tmp/cameranoise-cli-test.XXXXXX)
    trap 'rm -rf -- "$mock_dir"' EXIT
    cat >"$mock_dir/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*"
EOF
    chmod 0755 "$mock_dir/sudo"

    for strength in $(seq -100 10 100); do
        output=$(PATH="$mock_dir:$PATH" "$PROJECT_DIR/bin/cameranoise" "$strength")
        grep -Fq -- "-- $PROJECT_DIR/bin/cameranoise $strength" <<<"$output"
    done

    output=$(PATH="$mock_dir:$PATH" "$PROJECT_DIR/bin/cameranoise" +100)
    grep -Fq -- "-- $PROJECT_DIR/bin/cameranoise 100" <<<"$output"
fi

if [[ -x /usr/bin/python3 ]] &&
   /usr/bin/python3 -c 'import gi' >/dev/null 2>&1; then
    for strength in $(seq -100 10 100); do
        output=$(
            env \
                CAMERANOISE_STRENGTH="$strength" \
                LD_PRELOAD="$LIBRARY" \
                /usr/bin/python3 -c '
import gi
gi.require_version("Gst", "1.0")
from gi.repository import Gst
Gst.init(None)
source = Gst.ElementFactory.make("icamerasrc")
assert source is not None
source.set_property("wdr-level", 0)
' 2>&1
        )
        grep -Fq "cameranoise: applying manual HAL NR strength $strength" <<<"$output"
    done

    output=$(
        env \
            CAMERANOISE_STRENGTH=5 \
            LD_PRELOAD="$LIBRARY" \
            /usr/bin/python3 -c '
import gi
gi.require_version("Gst", "1.0")
from gi.repository import Gst
Gst.init(None)
source = Gst.ElementFactory.make("icamerasrc")
assert source is not None
source.set_property("wdr-level", 0)
' 2>&1
    )
    grep -Fq 'invalid CAMERANOISE_STRENGTH; falling back to -100' <<<"$output"
    printf 'Validated all 21 manual HAL strengths without opening a camera stream.\n'
else
    printf 'Skipped GStreamer interposition test: system Python GI is unavailable.\n'
fi

printf 'All ipu6-nr-control tests passed.\n'
