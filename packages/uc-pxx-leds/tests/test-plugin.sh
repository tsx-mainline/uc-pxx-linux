#!/bin/sh
# Host test for the ESPHome plugin of the package (esphome.d/uc-pxx-leds.py).
# It runs the plugin against the tsx_panel code of tsx-linux-common, with a
# stand-in for the daemon on a real unix socket, a made-up /sys/class/leds and
# a made-up state file. It checks:
#   - the loader loads the file; the entities, their fixed object ids and keys
#   - no key_leds_release button; the entity category of the lights is none
#   - the commands that Home Assistant sends and what the poll shows
#   - a refused command, a missing daemon, parts that are missing
# TSX_COMMON names the checkout of tsx-linux-common (default: ../tsx-linux-common
# next to the repository). Without it the test prints SKIPPED. Small stand-ins
# replace aioesphomeapi, protobuf and linux_voice_assistant. The test writes no
# file into the checkout of common.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
PLUGIN=$HERE/root/usr/local/share/tsx/esphome.d/uc-pxx-leds.py
COMMON=${TSX_COMMON:-$HERE/../../../tsx-linux-common}
SHIM=$COMMON/ha/voice/shim
command -v python3 >/dev/null 2>&1 || { echo "SKIPPED: no python3"; exit 0; }
[ -f "$SHIM/tsx_panel/plugins.py" ] || { echo "SKIPPED: no tsx-linux-common (set TSX_COMMON)"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export PYTHONDONTWRITEBYTECODE=1
mkdir -p "$T/stub/aioesphomeapi" "$T/stub/google/protobuf" "$T/stub/linux_voice_assistant" "$T/pd"
: > "$T/stub/aioesphomeapi/__init__.py"
cat > "$T/stub/aioesphomeapi/api_pb2.py" <<'PY'
_classes = {}
def __getattr__(name):
    if name.startswith("__"):
        raise AttributeError(name)
    if name not in _classes:
        _classes[name] = type(name, (), {"__init__": lambda self, **kw: self.__dict__.update(kw)})
    return _classes[name]
PY
: > "$T/stub/google/__init__.py"; : > "$T/stub/google/protobuf/__init__.py"
echo "class Message: pass" > "$T/stub/google/protobuf/message.py"
: > "$T/stub/linux_voice_assistant/__init__.py"
# LEDLightEntity as in linux-voice-assistant 1.1.15 (entity.py), reduced to what the plugin uses.
# Like the original, it lists its entity with entity_category CONFIG (1).
cat > "$T/stub/linux_voice_assistant/entity.py" <<'PY'
from aioesphomeapi import api_pb2 as pb

class ESPHomeEntity:
    def __init__(self, server):
        self.server = server

class LEDLightEntity(ESPHomeEntity):
    def __init__(self, server, key, name, object_id, effects=None, supports_rgb=True,
                 supports_brightness=True, on_changed=None, icon="mdi:led-strip-variant"):
        ESPHomeEntity.__init__(self, server)
        self.key, self.name, self.object_id, self.icon = key, name, object_id, icon
        self._on_changed = on_changed
        self.effects_list = list(effects) if effects else []
        self._supports_rgb, self._supports_brightness = supports_rgb, supports_brightness
        self.is_on, self.brightness = False, 0.66
        self.red, self.green, self.blue = 0.094, 0.733, 0.949
        self.effect = self.effects_list[0] if self.effects_list else ""

    def update_on_changed(self, on_changed):
        self._on_changed = on_changed

    def _color_mode(self):
        return "rgb" if self._supports_rgb else "brightness" if self._supports_brightness else "onoff"

    def handle_message(self, msg):
        if isinstance(msg, pb.LightCommandRequest) and msg.key == self.key:
            changed = False
            if getattr(msg, "has_state", False):
                self.is_on, changed = bool(msg.state), True
            if getattr(msg, "has_brightness", False) and self._supports_brightness:
                self.brightness, changed = float(msg.brightness), True
            if getattr(msg, "has_rgb", False) and self._supports_rgb:
                self.red, self.green, self.blue, changed = float(msg.red), float(msg.green), float(msg.blue), True
            if getattr(msg, "has_effect", False):
                if str(msg.effect) in self.effects_list:
                    self.effect, changed = str(msg.effect), True
            if changed and self._on_changed is not None:
                self._on_changed()
            yield self._state_response()
        elif isinstance(msg, pb.ListEntitiesRequest):
            yield pb.ListEntitiesLightResponse(object_id=self.object_id, key=self.key, name=self.name,
                                               supported_color_modes=[self._color_mode()],
                                               effects=self.effects_list, icon=self.icon, entity_category=1)
        elif isinstance(msg, pb.SubscribeHomeAssistantStatesRequest):
            yield self._state_response()

    def _state_response(self):
        return pb.LightStateResponse(key=self.key, state=self.is_on, brightness=self.brightness,
                                     color_brightness=self.brightness, red=self.red, green=self.green,
                                     blue=self.blue, effect=self.effect)
PY
# the plugin folder: a copy with fixed modes
mkdir "$T/pd/good"; cp "$PLUGIN" "$T/pd/good/uc-pxx-leds.py"; chmod 755 "$T/pd/good"; chmod 644 "$T/pd/good/uc-pxx-leds.py"
python3 -I -B "$HERE/tests/check_plugin.py" "$SHIM" "$T" "$PLUGIN"
