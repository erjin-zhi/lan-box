"""Exercise release rejection paths without Keychain, network, or GitHub writes."""
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import zipfile

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/release-config.py'
spec = importlib.util.spec_from_file_location('release_config', SCRIPT)
release_config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release_config)


class ReleaseValidationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.root_patch = patch.object(release_config, 'ROOT', self.root)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)
        self.config = {
            'version': '1.1.0', 'repository': 'example/lan-box',
            'feedURL': 'https://github.com/example/lan-box/releases/latest/download/appcast.xml',
            'publicEDKey': base64.b64encode(bytes(32)).decode(),
            'keychainAccount': 'test-only-no-keychain-access',
        }
        (self.root / 'Resources').mkdir()
        (self.root / 'Resources/UpdateConfig.json').write_text(json.dumps(self.config))
        self.directory = self.root / 'release'
        self.directory.mkdir()
        app = self.root / 'LanBox.app'
        (app / 'Contents').mkdir(parents=True)
        self.build = '20261031120000'
        release_config.write_plist(app, self.build)
        self.archive = release_config.archive_path(self.directory, self.config)
        with zipfile.ZipFile(self.archive, 'w') as archive:
            archive.write(app / 'Contents/Info.plist', 'LanBox.app/Contents/Info.plist')
            archive.writestr('LanBox.app/Contents/MacOS/LanBox', b'fixture-binary')
        self.tree = ET.ElementTree(ET.fromstring('<rss><channel><item/></channel></rss>'))
        self.item = self.tree.find('./channel/item')
        ET.SubElement(self.item, release_config.SPARKLE + 'version').text = self.build
        ET.SubElement(self.item, release_config.SPARKLE + 'shortVersionString').text = '1.1.0'
        self.enclosure = ET.SubElement(self.item, 'enclosure', {
            'url': f'https://github.com/example/lan-box/releases/download/v1.1.0/{self.archive.name}',
            'length': str(self.archive.stat().st_size),
            release_config.SPARKLE + 'edSignature': base64.b64encode(bytes(64)).decode(),
        })
        self.save_feed()
        self.metadata = {
            'version': '1.1.0', 'build': self.build,
            'sourceRevision': 'a' * 40, 'sourceDirty': False,
        }
        self.save_metadata()
        self.refresh_checksums()
        self.latest = {'tag_name': 'v1.0.0', 'assets': []}
        self.remote_tag = self.metadata['sourceRevision']
        self.current_revision = self.metadata['sourceRevision']
        self.working_changes = ''
        self.old_feed = ''
        self.key = self.config['publicEDKey']

    def save_feed(self):
        self.tree.write(self.directory / 'appcast.xml', encoding='utf-8')

    def save_metadata(self):
        (self.directory / 'release.json').write_text(json.dumps(self.metadata))

    def refresh_checksums(self):
        lines = []
        for name in (self.archive.name, 'appcast.xml'):
            digest = hashlib.sha256((self.directory / name).read_bytes()).hexdigest()
            lines.append(f'{digest}  {name}\n')
        (self.directory / 'SHA256SUMS.txt').write_text(''.join(lines))

    def fake_read(self, *args):
        if args == ('getconf', 'DARWIN_USER_CACHE_DIR'):
            return str(self.root / 'cache')
        if args[0].endswith('/generate_keys'):
            return self.key
        if args == ('git', 'status', '--porcelain'):
            return self.working_changes
        if args == ('git', 'rev-parse', 'HEAD'):
            return self.current_revision
        if args[0:2] == ('gh', 'api'):
            endpoint = args[-1] if '-H' in args else args[2]
            if '/commits/' in endpoint:
                return self.remote_tag
            if endpoint.endswith('/releases/latest'):
                return json.dumps(self.latest)
            if '/releases/assets/' in endpoint:
                return self.old_feed
        raise AssertionError(f'Unexpected external command: {args}')

    def validate(self, publication=False):
        with patch.object(release_config, 'run', side_effect=self.fake_read), \
             patch.object(release_config.subprocess, 'run') as signer:
            release_config.validate(self.directory, publication)
            self.assertEqual(signer.call_count, 2)
            for call in signer.call_args_list:
                self.assertIn('--verify', call.args[0])

    def test_complete_release_passes_without_external_access(self):
        self.validate(publication=True)

    def test_wrong_download_destination_is_rejected(self):
        self.enclosure.set('url', 'https://example.com/unrelated.zip')
        self.save_feed()
        self.refresh_checksums()
        with self.assertRaisesRegex(ValueError, '下载地址'):
            self.validate()

    def test_changed_archive_bytes_are_rejected(self):
        data = self.archive.read_bytes()
        self.archive.write_bytes(data.replace(b'fixture-binary', b'fixture-Binary'))
        with self.assertRaisesRegex(ValueError, '校验不一致'):
            self.validate()

    def test_wrong_signing_key_is_rejected(self):
        self.key = base64.b64encode(bytes([1]) * 32).decode()
        with self.assertRaisesRegex(ValueError, '公钥'):
            self.validate()

    def test_dirty_or_different_source_is_rejected(self):
        for field, value, message in (
            ('sourceDirty', True, '未提交'),
            ('sourceRevision', 'b' * 40, '当前提交'),
        ):
            with self.subTest(field=field):
                original = self.metadata[field]
                self.metadata[field] = value
                self.save_metadata()
                with self.assertRaisesRegex(ValueError, message):
                    self.validate(publication=True)
                self.metadata[field] = original
                self.save_metadata()

    def test_uncommitted_worktree_is_rejected(self):
        self.working_changes = ' M Sources/LanBox/main.swift'
        with self.assertRaisesRegex(ValueError, '源代码更改'):
            self.validate(publication=True)

    def test_wrong_remote_tag_is_rejected(self):
        self.remote_tag = 'b' * 40
        with self.assertRaisesRegex(ValueError, '远程版本标签'):
            self.validate(publication=True)

    def test_nonincrementing_build_is_rejected(self):
        self.latest['assets'] = [{'name': 'appcast.xml', 'id': 1}]
        self.old_feed = (self.directory / 'appcast.xml').read_text()
        with self.assertRaisesRegex(ValueError, '构建号必须严格递增'):
            self.validate(publication=True)

    def test_uploaded_assets_must_be_complete_and_match_local_bytes(self):
        assets = []
        for name in (self.archive.name, 'appcast.xml', 'SHA256SUMS.txt'):
            data = (self.directory / name).read_bytes()
            assets.append({'name': name, 'state': 'uploaded', 'size': len(data),
                           'digest': 'sha256:' + hashlib.sha256(data).hexdigest()})
        release = {'tag_name': 'v1.1.0', 'draft': True, 'assets': assets}
        record = self.directory / 'github-release.json'
        record.write_text(json.dumps(release))
        release_config.validate_uploaded_assets(self.directory)
        for field, value, message in (
            ('state', 'open', '上传不完整'),
            ('size', -1, '上传不完整'),
            ('digest', None, '上传校验失败'),
        ):
            with self.subTest(field=field):
                original = assets[0][field]
                assets[0][field] = value
                record.write_text(json.dumps(release))
                with self.assertRaisesRegex(ValueError, message):
                    release_config.validate_uploaded_assets(self.directory)
                assets[0][field] = original
        release['draft'] = False
        record.write_text(json.dumps(release))
        with self.assertRaisesRegex(ValueError, 'draft'):
            release_config.validate_uploaded_assets(self.directory)


if __name__ == '__main__':
    unittest.main()
