#!/usr/bin/env python3
"""Dispatch the tested source to EAS and retrieve only the expected Mac assets."""
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from version import parse


def build_number(now):
    minutes = int((now - datetime.datetime(2020, 1, 1, tzinfo=datetime.timezone.utc)).total_seconds() // 60)
    return f'{minutes // 10000}.{minutes // 100 % 100}.{minutes % 100}'


def expected_assets(tag):
    _, preview = parse(tag)
    return {f'AFK-{tag}-macOS.dmg', f'AFK-{tag}-macOS.zip', 'SHA256SUMS',
            'afk@preview.rb' if preview else 'afk.rb'}


def extract_assets(archive, destination, tag):
    expected = expected_assets(tag)
    with zipfile.ZipFile(archive) as bundle:
        files = {}
        for item in bundle.infolist():
            if item.is_dir():
                continue
            name = Path(item.filename).name
            if name not in expected or name in files:
                raise ValueError('Unexpected or duplicate release artifact')
            files[name] = item
        if set(files) != expected:
            raise ValueError('Incomplete Mac release artifacts')
        destination.mkdir(exist_ok=True)
        for name, item in files.items():
            (destination / name).write_bytes(bundle.read(item))


def main():
    tag, platform = sys.argv[1:]
    parse(tag)
    if platform not in ('all', 'ios'):
        raise ValueError('Expected all or ios')
    if subprocess.check_output(['git', 'status', '--porcelain']).strip():
        raise ValueError('Delivery requires a clean source tree')
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    number = build_number(datetime.datetime.now(datetime.timezone.utc))
    # Export only tracked files: never upload local .env, signing keys or build output.
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        source = root / 'source'
        source.mkdir()
        archive = root / 'source.tar'
        subprocess.run(['git', 'archive', '--format=tar', '-o', str(archive), commit], check=True)
        subprocess.run(['tar', '-xf', str(archive), '-C', str(source)], check=True)
        (source / '.afk-source-commit').write_text(commit + '\n')
        subprocess.run(['git', 'init', '-q', str(source)], check=True)
        subprocess.run(['git', 'add', '.'], cwd=source, check=True)
        subprocess.run(['git', '-c', 'user.name=AFK Delivery', '-c', 'user.email=delivery@localhost',
                        '-c', 'commit.gpgsign=false', 'commit', '-qm', f'Source {commit}'], cwd=source, check=True)
        command = ['eas', 'workflow:run', '.eas/workflows/apple.yml', '--non-interactive', '--wait', '--json',
                   '-F', f'tag={tag}', '-F', f'build={number}', '-F', f'commit={commit}', '-F', f'platform={platform}']
        result = subprocess.run(command, cwd=source, stdout=subprocess.PIPE, text=True)
        # Preserve the run ID on failures too, so operators can inspect before retrying an upload.
        run = json.loads(result.stdout)
        print(f'EAS run: {run["id"]}; Apple build: {number}', flush=True)
        result.check_returncode()
        detail = json.loads(subprocess.check_output(['eas', 'workflow:view', run['id'], '--json', '--non-interactive'], cwd=source))
        if platform == 'all':
            job = next(job for job in detail['jobs'] if job['key'] == 'mac')
            artifacts = job.get('artifacts') or []
            if len(artifacts) != 1:
                raise ValueError('Expected exactly one Mac artifact bundle')
            url = artifacts[0]['downloadUrl']
            if not url.startswith('https://'):
                raise ValueError('Expected HTTPS artifact download')
            bundle = root / 'mac.zip'
            urllib.request.urlretrieve(url, bundle)
            extract_assets(bundle, Path('dist'), tag)
            subprocess.run(['shasum', '-a', '256', '-c', 'SHA256SUMS'], cwd='dist', check=True)
        summary = os.environ.get('GITHUB_STEP_SUMMARY')
        if summary:
            with open(summary, 'a') as handle:
                handle.write(f'Apple build {number}, source `{commit}`, EAS run `{run["id"]}`.\n')


if __name__ == '__main__':
    main()
