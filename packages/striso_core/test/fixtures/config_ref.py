"""Reference outputs from the firmware's tools/striso.py for the config writer (no board involved).

Usage: python -I config_ref.py <striso-control-firmware>/tools   (test/config_uf2_test.dart runs it)
stdin: JSON list of cases {"current": base64 UF2, "touch": [[name, value]], "keys": [[name, value]]}
        or {"fmt8": value}
stdout: JSON list of base64 UF2 (or fmt8 strings, or {"error": message})
The update list mirrors striso.save_touch() line by line (save_touch itself reads the board).
"""
import base64
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[1]).resolve()))  # striso-control-firmware/tools
import striso  # noqa: E402


def save_touch_updates(touch, keys):
    # == striso.save_touch(), with touch/keys given instead of read from the board
    names = {"pressure": "presS", "velocity": "veloS", "tilt": "tiltS", "bend": "bendS", "threshold": "thres"}
    updates = {"iGpreset": "1"}
    for name, val in touch:
        updates["fP1" + names[name]] = striso.fmt8(val)
    remove = []
    for name, val in keys:
        key = "fCfac" + name
        if abs(val - 1.0) > 1e-4:
            updates[key] = striso.fmt8(val)
        else:
            remove.append(key)
    return updates, remove


def run(case):
    if "fmt8" in case:
        return striso.fmt8(case["fmt8"])
    try:
        current = base64.b64decode(case["current"])
        updates, remove = save_touch_updates(case["touch"], case["keys"])
        # == striso.config_update() without the drive
        recs = [(k, v) for k, v in striso.config_parse(current) if k not in updates and k not in remove]
        recs += list(updates.items())
        return base64.b64encode(striso.config_uf2(recs)).decode()
    except SystemExit as e:
        return {"error": str(e)}


print(json.dumps([run(c) for c in json.load(sys.stdin)]))
