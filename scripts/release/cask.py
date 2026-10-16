#!/usr/bin/env python3
"""Generate the cask from the exact notarized release archive."""
import hashlib
from pathlib import Path
import sys
from version import parse

tag, archive, destination = sys.argv[1:]
_, preview = parse(tag)
token = "afk@preview" if preview else "afk"
checksum = hashlib.sha256(Path(archive).read_bytes()).hexdigest()
conflict = "afk" if preview else "afk@preview"
Path(destination).write_text(f'''cask "{token}" do
  version "{tag[1:]}"
  sha256 "{checksum}"

  url "https://github.com/JesusPaz/afk/releases/download/v#{{version}}/AFK-v#{{version}}-macOS.zip"
  name "AFK"
  desc "Share your Mac terminal with your iPhone"
  homepage "https://github.com/JesusPaz/afk"

  conflicts_with cask: "{conflict}"
  depends_on macos: ">= :sonoma"

  app "AFK.app"
end
''')
