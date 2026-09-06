#!/usr/bin/env python3
"""Split the active workspace into two columns at a given ratio.

Usage: hypr-split.py <left-fraction>     e.g. 0.3333 -> left column is 1/3 wide

The fraction always describes the LEFT column and the resize is applied to the
left column explicitly, so focus doesn't matter -- whatever is in the left/right
column stays there and just changes width.

Two hyprland quirks this works around:
  * this setup runs the lua config plugin, so `hyprctl dispatch` takes a lua
    expression, not the usual `resizeactive exact ...` string;
  * an exact resize aimed at the right-hand column comes out inverted, hence
    always targeting the left window by address.
"""
import json
import subprocess
import sys


def hyprctl(*args):
    return subprocess.run(["hyprctl", *args], capture_output=True, text=True, check=True).stdout


def main():
    left_frac = float(sys.argv[1])

    # Whatever the focused monitor is actually showing: a special workspace when
    # one is pulled up (SUPER + D and friends), otherwise its normal workspace.
    mon = next(m for m in json.loads(hyprctl("monitors", "-j")) if m["focused"])
    special = mon["specialWorkspace"]
    ws = special["id"] if special["id"] != 0 else mon["activeWorkspace"]["id"]

    tiled = [
        c for c in json.loads(hyprctl("clients", "-j"))
        if c["workspace"]["id"] == ws and not c["floating"] and c["mapped"] and not c["hidden"]
    ]

    # Group the tiled windows into columns by their left edge. Taking the total
    # from the windows themselves keeps this free of gap/border arithmetic.
    columns = {}
    for c in tiled:
        columns.setdefault(c["at"][0], []).append(c)
    if len(columns) != 2:
        return  # not a two-column layout; nothing unambiguous to do

    left_x, right_x = sorted(columns)
    total = max(c["size"][0] for c in columns[left_x]) + max(c["size"][0] for c in columns[right_x])

    target = min(columns[left_x], key=lambda c: c["at"][1])
    hyprctl("dispatch", "hl.dsp.window.resize({{ x = {}, y = {}, relative = false, window = \"address:{}\" }})".format(
        round(total * left_frac), target["size"][1], target["address"]))


if __name__ == "__main__":
    main()
