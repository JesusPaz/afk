import datetime
import importlib.util
from pathlib import Path
import tempfile
import unittest
import tarfile
import io

spec = importlib.util.spec_from_file_location('delivery', Path(__file__).with_name('eas-delivery.py'))
delivery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delivery)


class DeliveryTests(unittest.TestCase):
    def test_build_numbers_are_ordered_and_exceed_local_builds(self):
        now = datetime.datetime(2026, 10, 17, tzinfo=datetime.timezone.utc)
        first = tuple(map(int, delivery.build_number(now).split('.')))
        later = tuple(map(int, delivery.build_number(now + datetime.timedelta(minutes=1)).split('.')))
        self.assertGreater(first, (7, 0, 0))
        self.assertGreater(later, first)
        self.assertLessEqual(first[0], 9999)
        self.assertTrue(all(0 <= value <= 99 for value in first[1:]))

    def test_download_requires_complete_exact_assets(self):
        for tag in ('v0.1.0-rc.8', 'v0.1.0'):
            expected = delivery.expected_assets(tag)
            for variant in ('valid', 'missing', 'extra', 'duplicate'):
                with self.subTest(tag=tag, variant=variant), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    bundle = root / 'bundle.tar.gz'
                    names = sorted(expected)
                    if variant == 'missing':
                        names.pop()
                    if variant == 'extra':
                        names.append('AuthKey.p8')
                    if variant == 'duplicate':
                        names.append('other/' + names[0])
                    with tarfile.open(bundle, 'w:gz') as archive:
                        for name in names:
                            data = b'expected artifact'
                            item = tarfile.TarInfo('dist/' + name)
                            item.size = len(data)
                            archive.addfile(item, io.BytesIO(data))
                    if variant == 'valid':
                        delivery.extract_assets(bundle, root / 'dist', tag)
                        self.assertEqual({p.name for p in (root / 'dist').iterdir()}, expected)
                    else:
                        with self.assertRaises(ValueError):
                            delivery.extract_assets(bundle, root / 'dist', tag)
