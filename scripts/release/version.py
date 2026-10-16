#!/usr/bin/env python3
"""Validate the explicit release tag; never guess the next version."""
import re
import sys


def parse(tag):
    number = r"(?:0|[1-9][0-9]*)"
    match = re.fullmatch(rf"v({number}\.{number}\.{number})(?:-rc\.([1-9][0-9]*))?", tag)
    if not match:
        raise ValueError("Use vX.Y.Z or vX.Y.Z-rc.N (no leading zeros).")
    if any(int(part) > 9999 for part in match[1].split(".")):
        raise ValueError("Apple version components must not exceed 9999.")
    return match[1], match[2] is not None


if __name__ == "__main__":
    try:
        version, preview = parse(sys.argv[1])
    except (IndexError, ValueError) as error:
        sys.exit(str(error))
    print(f"version={version}")
    print(f"prerelease={str(preview).lower()}")
