// Service-scoped compatibility shim for Intel icamerasrc.
//
// The installed Intel camera HAL exposes Parameters::setNrLevel(), but the
// installed icamerasrc plugin does not expose it as a GStreamer property.
// v4l2-relayd sets icamerasrc's otherwise-unused wdr-level property; this shim
// intercepts that setter and translates CAMERANOISE_STRENGTH into a manual
// noise-reduction level.

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <unistd.h>

namespace icamera {

struct camera_nr_level_t {
    int overall;
    int spatial;
    int temporal;
};

class Parameters {
public:
    int setNrLevel(camera_nr_level_t level);
    int setWdrLevel(std::uint8_t level);
};

namespace {

struct Selection {
    int strength;
    bool valid;
};

Selection selectStrength() {
    const char* requested = std::getenv("CAMERANOISE_STRENGTH");

    if (requested == nullptr) {
        return {-100, true};
    }

    errno = 0;
    char* end = nullptr;
    const long parsed = std::strtol(requested, &end, 10);
    const bool is_integer =
        errno == 0 && end != requested && end != nullptr && *end == '\0';
    const bool in_range = parsed >= -100 && parsed <= 100;
    const bool is_ten_step = parsed % 10 == 0;

    if (is_integer && in_range && is_ten_step) {
        return {static_cast<int>(parsed), true};
    }

    return {-100, false};
}

void logSelection(const Selection& selection) {
    char message[192];
    int count;

    if (selection.valid) {
        count = std::snprintf(
            message,
            sizeof(message),
            "cameranoise: applying manual HAL NR strength %d\n",
            selection.strength);
    } else {
        count = std::snprintf(
            message,
            sizeof(message),
            "cameranoise: invalid CAMERANOISE_STRENGTH; falling back to -100\n");
    }

    if (count <= 0) {
        return;
    }

    std::size_t length = static_cast<std::size_t>(count);
    if (length >= sizeof(message)) {
        length = sizeof(message) - 1;
    }
    const ssize_t bytes_written = ::write(STDERR_FILENO, message, length);
    static_cast<void>(bytes_written);
}

}  // namespace

int Parameters::setWdrLevel(std::uint8_t /* level */) {
    const Selection selection = selectStrength();
    logSelection(selection);
    const camera_nr_level_t level = {
        selection.strength,
        selection.strength,
        selection.strength,
    };
    return setNrLevel(level);
}

}  // namespace icamera
