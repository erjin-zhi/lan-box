#!/usr/bin/env python3
"""Release metadata and validation. This file never reads or exports a private key."""
import base64
import hashlib
import json
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def build_path():
    cache = run('getconf', 'DARWIN_USER_CACHE_DIR')
    require(cache and Path(cache).is_absolute(), '无法确定本机 SwiftPM 缓存目录')
    repository_id = hashlib.sha256(str(ROOT.resolve()).encode()).hexdigest()[:12]
    return Path(cache) / f'LanBox-SwiftPM-{repository_id}'


def config():
    value = json.loads((ROOT / 'Resources/UpdateConfig.json').read_text())
    require(re.fullmatch(r'\d+\.\d+\.\d+', value['version']), '版本必须为 x.y.z')
    require(re.fullmatch(r'[\w.-]+/[\w.-]+', value['repository']), '仓库格式无效')
    expected = f"https://github.com/{value['repository']}/releases/latest/download/appcast.xml"
    require(value['feedURL'] == expected, '更新源必须指向当前仓库的最新 Release')
    require(len(base64.b64decode(value['publicEDKey'], validate=True)) == 32, '缺少有效的 Ed25519 公钥')
    require(value['keychainAccount'], '缺少 Keychain 账号')
    return value


def write_plist(app, build):
    c = config()
    require(re.fullmatch(r'\d{14}', build), '构建号必须为 14 位 UTC 时间戳')
    value = {
        'CFBundleIdentifier': 'app.lanbox.mac',
        'CFBundleName': 'LanBox', 'CFBundleDisplayName': 'LanBox',
        'CFBundleExecutable': 'LanBox', 'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': c['version'], 'CFBundleVersion': build,
        'CFBundleIconFile': 'AppIcon', 'CFBundleDevelopmentRegion': 'zh_CN',
        'LSMinimumSystemVersion': '26.0', 'LSUIElement': True,
        'LSApplicationCategoryType': 'public.app-category.utilities',
        'NSLocalNetworkUsageDescription': 'LanBox 需要使用局域网，让同一网络中的手机和电脑访问你共享的文件。',
        'NSSupportsAutomaticTermination': False,
        'CFBundleDocumentTypes': [{
            'CFBundleTypeName': '共享的项目', 'CFBundleTypeRole': 'Viewer',
            'LSHandlerRank': 'None', 'LSItemContentTypes': ['public.item', 'public.folder'],
        }],
        'SUFeedURL': c['feedURL'], 'SUPublicEDKey': c['publicEDKey'],
        'SUEnableAutomaticChecks': True, 'SUScheduledCheckInterval': 86400,
        'SUAllowsAutomaticUpdates': False, 'SUAutomaticallyUpdate': False,
        'SUEnableSystemProfiling': False, 'SUVerifyUpdateBeforeExtraction': True,
        'SURequireSignedFeed': True,
    }
    (Path(app) / 'Contents/Info.plist').write_bytes(plistlib.dumps(value))


def archive_path(directory, c):
    return directory / f"LanBox-{c['version']}-macOS-universal.zip"


def app_info(archive):
    with zipfile.ZipFile(archive) as z:
        require(all(n.startswith('LanBox.app/') for n in z.namelist()), 'ZIP 应只包含 LanBox.app')
        return plistlib.loads(z.read('LanBox.app/Contents/Info.plist'))


def manifest(directory):
    c = config()
    info = app_info(archive_path(directory, c))
    result = {
        'version': c['version'], 'build': info['CFBundleVersion'],
        'sourceRevision': run('git', 'rev-parse', 'HEAD'),
        'sourceDirty': bool(run('git', 'status', '--porcelain')),
    }
    (directory / 'release.json').write_text(json.dumps(result, indent=2) + '\n')


def validate_uploaded_assets(directory):
    c = config()
    release = json.loads((directory / 'github-release.json').read_text())
    require(release['draft'] is True, '发布检查仅接受 draft')
    require(release['tag_name'] == f"v{c['version']}", '上传的 Release 标签不一致')
    assets = {asset['name']: asset for asset in release['assets']}
    for name in (archive_path(directory, c).name, 'appcast.xml', 'SHA256SUMS.txt'):
        require(name in assets, f'{name} 尚未上传')
        data = (directory / name).read_bytes()
        asset = assets[name]
        require(asset['state'] == 'uploaded' and asset['size'] == len(data), f'{name} 上传不完整')
        require(asset.get('digest') == 'sha256:' + hashlib.sha256(data).hexdigest(), f'{name} 上传校验失败')
    print('GitHub Release 附件大小与 SHA-256 均通过检查。')


def validate(directory, publication=False):
    c = config()
    archive = archive_path(directory, c)
    info = app_info(archive)
    require(info['CFBundleIdentifier'] == 'app.lanbox.mac', '发布元数据不一致')
    require(info['CFBundleShortVersionString'] == c['version'], '发布元数据不一致')
    require(info['SUPublicEDKey'] == c['publicEDKey'], '发布元数据不一致')
    require(info['SUFeedURL'] == c['feedURL'], '发布元数据不一致')
    require(info['SURequireSignedFeed'] and info['SUVerifyUpdateBeforeExtraction'], '发布元数据不一致')
    item = ET.parse(directory / 'appcast.xml').getroot().find('./channel/item')
    require(item is not None, 'appcast 中没有更新条目')
    require(item.findtext(SPARKLE + 'version') == info['CFBundleVersion'], 'appcast 构建号不一致')
    require(item.findtext(SPARKLE + 'shortVersionString') == c['version'], '发布元数据不一致')
    enclosure = item.find('enclosure')
    require(enclosure is not None, 'appcast 缺少下载信息')
    expected = f"https://github.com/{c['repository']}/releases/download/v{c['version']}/{archive.name}"
    require(enclosure.get('url') == expected, 'appcast 下载地址不一致')
    require(int(enclosure.get('length')) == archive.stat().st_size, 'appcast 文件长度不一致')
    signature = enclosure.get(SPARKLE + 'edSignature', '')
    require(len(base64.b64decode(signature, validate=True)) == 64, 'appcast 缺少更新签名')
    for name in (archive.name, 'appcast.xml'):
        expected_hash = hashlib.sha256((directory / name).read_bytes()).hexdigest()
        require(f'{expected_hash}  {name}\n' in (directory / 'SHA256SUMS.txt').read_text(), f'{name} 校验不一致')
    metadata = json.loads((directory / 'release.json').read_text())
    require(metadata['version'] == c['version'] and metadata['build'] == info['CFBundleVersion'], '发布元数据不一致')
    tools = build_path() / 'artifacts/sparkle/Sparkle/bin'
    public_key = run(str(tools / 'generate_keys'), '--account', c['keychainAccount'], '-p')
    require(public_key == c['publicEDKey'], '签名 Keychain 公钥与应用配置不一致')
    for file, sig in ((archive, signature), (directory / 'appcast.xml', None)):
        args = [str(tools / 'sign_update'), '--account', c['keychainAccount'], '--verify', str(file)]
        if sig:
            args.append(sig)
        subprocess.run(args, check=True, cwd=ROOT)
    if publication:
        require(metadata['sourceDirty'] is False, '发布包来自未提交的工作区，请提交后重新 prepare-release')
        require(not run('git', 'status', '--porcelain'), '发布前请提交所有源代码更改')
        require(metadata['sourceRevision'] == run('git', 'rev-parse', 'HEAD'), '发布包不是当前提交构建的')
        tag_commit = run('gh', 'api', f"repos/{c['repository']}/commits/v{c['version']}", '--jq', '.sha')
        require(tag_commit == metadata['sourceRevision'], '远程版本标签与构建提交不一致')
        latest = json.loads(run('gh', 'api', f"repos/{c['repository']}/releases/latest"))
        old_version = latest['tag_name'].removeprefix('v')
        require(re.fullmatch(r'\d+\.\d+\.\d+', old_version), '最新发布版本无法比较')
        require(tuple(map(int, c['version'].split('.'))) > tuple(map(int, old_version.split('.'))), '版本必须高于最新 Release')
        feed_asset = next((a for a in latest['assets'] if a['name'] == 'appcast.xml'), None)
        if feed_asset:
            # gh 保留 GitHub 的证书验证；不要通过自定义不验证证书的 HTTP 客户端下载。
            old_feed = run('gh', 'api', '-H', 'Accept: application/octet-stream', f"repos/{c['repository']}/releases/assets/{feed_asset['id']}")
            versions = [x.text for x in ET.fromstring(old_feed).findall('./channel/item/' + SPARKLE + 'version')]
            require(versions and all(isinstance(v, str) and v.isdecimal() for v in versions), '旧 appcast 构建号无法比较')
            require(int(info['CFBundleVersion']) > max(map(int, versions)), '构建号必须严格递增')
    print('发布包、配置、appcast、EdDSA 签名与校验文件一致。')


if __name__ == '__main__':
    try:
        command, *args = sys.argv[1:]
        if command == 'build-path': print(build_path())
        elif command == 'get': print(config()[args[0]])
        elif command == 'plist': write_plist(*args)
        elif command == 'manifest': manifest(Path(args[0]).resolve())
        elif command == 'check-upload': validate_uploaded_assets(Path(args[0]).resolve())
        elif command in ('validate', 'check-publish'): validate(Path(args[0]).resolve(), command == 'check-publish')
        else: raise ValueError('未知命令')
    except (ValueError, TypeError, KeyError, OSError, ET.ParseError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        sys.exit(f'发布检查失败：{error}')
