#!/usr/bin/env python3
import datetime
import os
import plistlib
import sys

with open(sys.argv[1], 'rb') as f:
    profile = plistlib.load(f)
team = os.environ['APPLE_TEAM_ID']
assert team in profile['TeamIdentifier'], 'Provisioning profile belongs to another team'
assert profile['Entitlements']['application-identifier'].endswith('.com.jesuspaz.afk.ios'), 'Profile must belong to AFK, not Testa'
assert not profile['Entitlements'].get('get-task-allow', False), 'Use an App Store distribution profile'
assert not profile.get('ProvisionedDevices') and not profile.get('ProvisionsAllDevices'), 'Use an App Store profile, not ad hoc/enterprise'
assert profile['ExpirationDate'] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), 'Profile expired'
