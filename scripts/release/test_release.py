import datetime
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from version import parse

SCRIPTS = Path(__file__).parent.resolve()


class ReleaseTests(unittest.TestCase):
    def test_versions(self):
        self.assertEqual(parse('v0.1.0-rc.1'), ('0.1.0', True))
        self.assertEqual(parse('v1.2.3'), ('1.2.3', False))
        for value in ['1.2.3', 'v01.2.3', 'v1.2.3-rc.0', 'v1.2.3;echo bad', 'v1.2.3\n', 'v10000.0.0']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                parse(value)

    def test_cask_tracks_exact_archive_and_channel(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive, cask = Path(tmp)/'app.zip', Path(tmp)/'afk.rb'
            archive.write_bytes(b'test signed archive')
            for tag, token in [('v1.2.3', 'afk'), ('v1.2.3-rc.2', 'afk@preview')]:
                subprocess.run([sys.executable, str(SCRIPTS/'cask.py'), tag, str(archive), str(cask)], check=True)
                text = cask.read_text()
                self.assertIn(f'cask "{token}"', text)
                self.assertIn(hashlib.sha256(archive.read_bytes()).hexdigest(), text)
                self.assertIn(f'version "{tag[1:]}"', text)
                self.assertIn('AFK-v#{version}-macOS.zip', text)

    def test_cask_uses_dmg_checksum_and_url(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive, cask = Path(tmp)/'app.dmg', Path(tmp)/'afk.rb'
            archive.write_bytes(b'notarized disk image')
            subprocess.run([sys.executable, str(SCRIPTS/'cask.py'), 'v0.1.0-rc.6', str(archive), str(cask)], check=True)
            text = cask.read_text()
            self.assertIn(hashlib.sha256(archive.read_bytes()).hexdigest(), text)
            self.assertIn('AFK-v#{version}-macOS.dmg', text)
            self.assertIn('app "AFK.app"', text)

    def test_profile_rejects_wrong_app_team_expiry_and_distribution(self):
        profile = dict(TeamIdentifier=['TESTTEAM'], Entitlements={'application-identifier': 'TESTTEAM.com.jesuspaz.afk.ios'},
                       ExpirationDate=datetime.datetime.now()+datetime.timedelta(days=30))
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'profile.plist'
            cases = [(profile, True), (dict(profile, TeamIdentifier=['OTHERTEAM']), False),
                     (dict(profile, ExpirationDate=datetime.datetime(2020, 1, 1)), False),
                     (dict(profile, ProvisionedDevices=['device']), False),
                     (dict(profile, ProvisionsAllDevices=True), False),
                     (dict(profile, Entitlements={'application-identifier': 'TESTTEAM.com.jesuspaz.testa'}), False),
                     (dict(profile, Entitlements={'application-identifier': 'TESTTEAM.com.jesuspaz.afk.ios', 'get-task-allow': True}), False)]
            for value, valid in cases:
                path.write_bytes(plistlib.dumps(value))
                result = subprocess.run([sys.executable, str(SCRIPTS/'check-profile.py'), str(path)],
                                        env=dict(os.environ, APPLE_TEAM_ID='TESTTEAM'), capture_output=True)
                self.assertEqual(result.returncode == 0, valid)

    def test_preflight_fails_before_using_missing_credentials(self):
        result = subprocess.run([sys.executable, str(SCRIPTS/'preflight.py'), 'mac'],
                                env={'RELEASE_TAG': 'v0.1.0-rc.1'}, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Missing release configuration', result.stderr)

    def test_preflight_rejects_non_https_and_credential_urls(self):
        env = dict(os.environ, RELEASE_TAG='v0.1.0', APPLE_TEAM_ID='test', P12_BASE64='test', P12_PASSWORD='test',
                   ASC_KEY_ID='test', ASC_ISSUER_ID='test', ASC_KEY_BASE64='test')
        for url in ['http://afk.example.com', 'https://localhost', 'https://token@afk.example.com', 'https://afk.example.com?secret=1']:
            result = subprocess.run([sys.executable, str(SCRIPTS/'preflight.py'), 'mac'],
                                    env=dict(env, AFK_RELAY_URL=url), capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn(b'Missing AppIcon', result.stderr)


if __name__ == '__main__':
    unittest.main()
