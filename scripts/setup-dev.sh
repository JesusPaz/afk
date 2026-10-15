#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
python3 - <<'PY'
from pathlib import Path
import secrets
import os
path = Path('.env')
try:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
except FileExistsError:
    print('Keeping existing .env')
else:
    with os.fdopen(fd, 'w') as f:
        f.write('AFK_DATABASE_PASSWORD=' + secrets.token_hex(24) + '\n')
    print('Created private .env with a random database password')
PY
