#!/usr/bin/python3
#
# fixDeviceProps.py - Patch WSA build.prop files to hide emulator/WSA identity
# and bypass security SDK detection (errors 709 / 607).
#
# Usage: python3 fixDeviceProps.py <system_mount_path> <vendor_mount_path>
#

from __future__ import annotations
from typing import OrderedDict
from pathlib import Path
import sys
import os


class Prop(OrderedDict):
    def __init__(self, text: str) -> None:
        super().__init__()
        for i, line in enumerate(text.splitlines(False)):
            if '=' in line and not line.lstrip().startswith('#'):
                k, _, v = line.partition('=')
                self[k] = v
            else:
                self[f".{i}"] = line

    def __str__(self) -> str:
        return '\n'.join(
            v if k.startswith('.') else f"{k}={v}"
            for k, v in self.items()
        )

    def __iadd__(self, other: str) -> 'Prop':
        self[f".{len(self)}"] = other
        return self


# ---------------------------------------------------------------------------
# Minimal security-only patches — preserve WSA device identity.
# Only clear the flags that trigger 709/607 (debug mode, test-keys, QEMU).
# Do NOT change fingerprint/brand/model: apps verify identity consistency
# against actual hardware and crash if it doesn't match.
# ---------------------------------------------------------------------------
OVERRIDE_PROPS: dict[str, str] = {
    # Build type / security flags (709 triggers)
    "ro.build.tags":                    "release-keys",
    "ro.build.type":                    "user",
    "ro.debuggable":                    "0",
    "ro.secure":                        "1",
    "ro.adb.secure":                    "1",
    # QEMU/emulator markers (607 triggers)
    "ro.kernel.qemu":                   "0",
    "ro.boot.qemu":                     "0",
    "ro.kernel.qemu.gles":              "0",
}


def patch_prop_file(prop_path: str) -> None:
    path = Path(prop_path)
    if not path.is_file():
        print(f"  skip  {prop_path} (not found)", flush=True)
        return

    print(f"  patch {prop_path}", flush=True)

    with open(path, 'r', errors='replace') as f:
        p = Prop(f.read())

    # Overwrite keys that already exist in the file
    written: set[str] = set()
    for k in list(p.keys()):
        if not k.startswith('.') and k in OVERRIDE_PROPS:
            p[k] = OVERRIDE_PROPS[k]
            written.add(k)

    # Append keys that were not present
    p += ""
    p += "# --- props injected by fixDeviceProps.py (security bypass) ---"
    for k, v in OVERRIDE_PROPS.items():
        if k not in written:
            p[k] = v

    tmp = path.with_suffix('.tmp')
    with open(tmp, 'w') as f:
        f.write(str(p) + '\n')
    tmp.replace(path)


def main() -> None:
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <system_mount> <vendor_mount>", file=sys.stderr)
        sys.exit(1)

    system_mnt = sys.argv[1]
    vendor_mnt = sys.argv[2]

    targets = [
        os.path.join(system_mnt, "build.prop"),
        os.path.join(vendor_mnt, "build.prop"),
        os.path.join(vendor_mnt, "odm", "etc", "build.prop"),
        os.path.join(vendor_mnt, "vendor_dlkm", "etc", "build.prop"),
    ]

    print("=== fixDeviceProps: patching build.prop files ===", flush=True)
    for t in targets:
        patch_prop_file(t)
    print("=== fixDeviceProps: done ===", flush=True)


if __name__ == "__main__":
    main()
