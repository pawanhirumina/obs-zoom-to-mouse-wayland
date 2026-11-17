#!/usr/bin/env python3
"""Global key listener for scripts/obs-key-display.lua.

Listens for key presses on the keyboard via evdev (non-exclusive grab — every
other app keeps receiving keyboard events normally) and writes each key press
to a file that the OBS Lua script reads and displays in a text source.

This is the same approach as bin/obs-zoom-hold.py in this project.

Requires:
    python3-evdev          (sudo apt install python3-evdev  /  sudo dnf install python3-evdev)
    access to /dev/input   (sudo usermod -aG input $USER, then log out/in)
                          or run this script with sudo

Usage:
    python3 bin/obs-key-log.py

Default output file:
    $XDG_STATE_HOME/obs-zoom-to-mouse-wayland/last-key.txt
    (~/.local/state/obs-zoom-to-mouse-wayland/last-key.txt)

Override with the OBS_KEY_LOG_FILE environment variable, e.g.:
    OBS_KEY_LOG_FILE=/tmp/obs-last-key.txt python3 bin/obs-key-log.py

Point the Lua script's "Key log file path" setting at the same file, then add
a Text (FreeType2) source to your scene and select it in the script settings.
"""

import os
import sys

try:
    from evdev import InputDevice, ecodes, list_devices, categorize
    from evdev.events import KeyEvent
except ImportError:
    print(
        "Missing dependency: install python3-evdev (or: pip install --user evdev)",
        file=sys.stderr,
    )
    sys.exit(1)

# Integer evdev codes for modifier keys.
MODIFIER_CODES = {
    ecodes.KEY_LEFTCTRL,
    ecodes.KEY_RIGHTCTRL,
    ecodes.KEY_LEFTALT,
    ecodes.KEY_RIGHTALT,
    ecodes.KEY_LEFTSHIFT,
    ecodes.KEY_RIGHTSHIFT,
    ecodes.KEY_LEFTMETA,
    ecodes.KEY_RIGHTMETA,
}

# Display order for modifiers when several are held.
MOD_ORDER = [
    ecodes.KEY_LEFTCTRL,
    ecodes.KEY_RIGHTCTRL,
    ecodes.KEY_LEFTALT,
    ecodes.KEY_RIGHTALT,
    ecodes.KEY_LEFTSHIFT,
    ecodes.KEY_RIGHTSHIFT,
    ecodes.KEY_LEFTMETA,
    ecodes.KEY_RIGHTMETA,
]

# Friendly label per modifier code (Left/Right variants collapse to one family).
MOD_LABELS = {
    ecodes.KEY_LEFTCTRL: "Ctrl",
    ecodes.KEY_RIGHTCTRL: "Ctrl",
    ecodes.KEY_LEFTALT: "Alt",
    ecodes.KEY_RIGHTALT: "Alt",
    ecodes.KEY_LEFTSHIFT: "Shift",
    ecodes.KEY_RIGHTSHIFT: "Shift",
    ecodes.KEY_LEFTMETA: "Super",
    ecodes.KEY_RIGHTMETA: "Super",
}

XDG_STATE = os.environ.get("XDG_STATE_HOME") or os.path.join(
    os.path.expanduser("~"), ".local", "state"
)
DEFAULT_DIR = os.path.join(XDG_STATE, "obs-zoom-to-mouse-wayland")
DEFAULT_FILE = os.path.join(DEFAULT_DIR, "last-key.txt")
KEY_FILE = os.environ.get("OBS_KEY_LOG_FILE", DEFAULT_FILE)

last_display = None


def ensure_dir():
    os.makedirs(os.path.dirname(KEY_FILE), exist_ok=True)


def write_key(text):
    global last_display
    if text == last_display:
        return  # don't spam the file on key repeat
    last_display = text
    ensure_dir()
    tmp = KEY_FILE + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, KEY_FILE)  # atomic, so the Lua script never reads a partial


def modifier_labels(mods):
    """Return a de-duplicated list of modifier family labels (Ctrl, Alt, …)."""
    labels = []
    seen = set()
    for code in MOD_ORDER:
        if code in mods:
            family = MOD_LABELS[code]
            if family in seen:
                continue
            seen.add(family)
            labels.append(family)
    return labels


def key_label(keycode):
    """'KEY_A' -> 'A'. keycode can occasionally be a list."""
    if isinstance(keycode, (list, tuple)):
        keycode = keycode[0] if keycode else ""
    return keycode[len("KEY_"):] if keycode.startswith("KEY_") else keycode


def find_keyboard():
    for path in list_devices():
        dev = InputDevice(path)
        caps = dev.capabilities()
        if ecodes.EV_KEY in caps and ecodes.KEY_A in caps[ecodes.EV_KEY]:
            return dev
        dev.close()
    raise RuntimeError("No keyboard device found")


def main():
    ensure_dir()
    device = find_keyboard()
    mods = set()  # stores integer evdev codes currently held
    try:
        for event in device.read_loop():
            if event.type != ecodes.EV_KEY:
                continue
            ke = categorize(event)
            code = event.code
            keycode = ke.keycode  # e.g. 'KEY_A'

            if code in MODIFIER_CODES:
                if ke.keystate == KeyEvent.key_down:
                    mods.add(code)
                    # Modifier pressed alone: show just the modifier name.
                    # Modifier + another key handled below when that key comes down.
                    labels = modifier_labels(mods)
                    if labels:
                        write_key(labels[0])
                elif ke.keystate == KeyEvent.key_up:
                    mods.discard(code)
                    if not mods:
                        # All modifiers released — clear so Lua can blank the text.
                        write_key("")
                continue

            # Only key presses (down), not releases.
            if ke.keystate != KeyEvent.key_down:
                continue

            labels = modifier_labels(mods)
            if labels:
                display = " + ".join(labels + [key_label(keycode)])
            else:
                display = key_label(keycode)

            write_key(display)
    finally:
        device.close()


if __name__ == "__main__":
    try:
        main()
    except PermissionError:
        print(
            "Permission denied: cannot access /dev/input. "
            "Run with sudo or add your user to the `input` group, then log out/in.",
            file=sys.stderr,
        )
        sys.exit(1)
    except RuntimeError as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)
