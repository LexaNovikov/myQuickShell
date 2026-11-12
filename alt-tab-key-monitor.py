#!/usr/bin/python3
"""Report only Alt key transitions from Niri's passive accessibility monitor."""

from gi.repository import Gio, GLib


BUS_NAME = "org.freedesktop.a11y.Manager"
OBJECT_PATH = "/org/freedesktop/a11y/Manager"
INTERFACE = "org.freedesktop.a11y.KeyboardMonitor"
ALT_KEYS = {0xFFE9, 0xFFEA}  # XKB Alt_L and Alt_R

connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
pressed = set()


def on_key_event(_connection, _sender, _path, _interface, _signal, parameters, _data):
    released, _state, keysym, _unichar, _keycode = parameters.unpack()
    if keysym not in ALT_KEYS:
        return

    if released:
        pressed.discard(keysym)
    else:
        pressed.add(keysym)
    print("down" if pressed else "up", flush=True)


connection.signal_subscribe(
    BUS_NAME, INTERFACE, "KeyEvent", OBJECT_PATH, None,
    Gio.DBusSignalFlags.NONE, on_key_event, None,
)
connection.call_sync(
    BUS_NAME, OBJECT_PATH, INTERFACE, "WatchKeyboard", None, None,
    Gio.DBusCallFlags.NONE, -1, None,
)
print("ready", flush=True)
GLib.MainLoop().run()
