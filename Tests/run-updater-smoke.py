#!/usr/bin/env python3
"""Exercise real Sparkle discovery, signatures, install and relaunch in isolation."""
import argparse
import functools
import http.server
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
import xml.etree.ElementTree as ET

REPO = Path(__file__).resolve().parents[1]
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def run(args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, capture_output=True, text=True, **kwargs).stdout.strip()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


class QuietServer(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--account", default="app.lanbox.mac.sparkle")
    parser.add_argument("--sparkle-root", type=Path, help="Override the Sparkle distribution in the project's external build cache.")
    parser.add_argument("--framework", type=Path, help="Use the Sparkle.framework embedded in a prepared release app.")
    parser.add_argument("--timeout", type=float, default=90)
    parser.add_argument("--keep", action="store_true", help="Keep disposable app fixtures after success.")
    options = parser.parse_args()
    if options.sparkle_root:
        sparkle = options.sparkle_root.resolve()
    else:
        build_path = Path(run(["python3", REPO / "scripts/release-config.py", "build-path"]))
        sparkle = build_path / "artifacts/sparkle/Sparkle"
    framework = (options.framework or sparkle / "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework").resolve()
    if not framework.is_dir():
        raise SystemExit('Sparkle is missing. Run swift package --scratch-path "$(python3 scripts/release-config.py build-path)" --disable-keychain resolve first, or pass --sparkle-root.')
    signer = sparkle / "bin/sign_update"
    public_key = run([sparkle / "bin/generate_keys", "--account", options.account, "-p"])
    # The private key stays in Keychain; only the public key and signatures are read.
    work = Path(tempfile.mkdtemp(prefix="lanbox-updater-smoke-"))
    report_dir = REPO / "output/updater-smoke"
    report_dir.mkdir(parents=True, exist_ok=True)
    # A failed rerun must never leave an earlier success report looking current.
    (report_dir / "results.json").unlink(missing_ok=True)
    print(f"Isolated fixtures: {work}", flush=True)
    binary = work / "UpdaterSmoke"
    run(["swiftc", REPO / "Tests/UpdaterSmoke.swift", "-F", framework.parent,
         "-framework", "Sparkle", "-framework", "AppKit", "-Xlinker", "-rpath",
         "-Xlinker", "@executable_path/../Frameworks", "-o", binary])
    handler = functools.partial(QuietServer, directory=str(work))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base_url = f"http://localhost:{server.server_port}"
    domains = []
    processes = []
    results = []
    success = False
    try:
        for scenario in ("install", "tampered-feed", "tampered-archive"):
            print(f"Running {scenario}…", flush=True)
            domain = "app.lanbox.smoke." + uuid.uuid4().hex
            domains.append(domain)
            case = work / scenario
            case.mkdir()
            log = case / "events.log"
            target = case / "installed/UpdaterSmoke.app"
            update = case / "update/UpdaterSmoke.app"
            url = f"{base_url}/{scenario}"
            for app, version in ((target, "1"), (update, "2")):
                contents = app / "Contents"
                (contents / "MacOS").mkdir(parents=True)
                shutil.copy2(binary, contents / "MacOS/UpdaterSmoke")
                shutil.copytree(framework, contents / "Frameworks/Sparkle.framework", symlinks=True)
                info = {
                    "CFBundleIdentifier": domain, "CFBundleName": "UpdaterSmoke",
                    "CFBundleExecutable": "UpdaterSmoke", "CFBundlePackageType": "APPL",
                    "CFBundleVersion": version, "CFBundleShortVersionString": version + ".0",
                    "LSMinimumSystemVersion": "26.0", "LSUIElement": True,
                    "SUFeedURL": url + "/appcast.xml", "SUPublicEDKey": public_key,
                    "SUEnableAutomaticChecks": False, "SUAutomaticallyUpdate": False,
                    "SUEnableSystemProfiling": False, "SUVerifyUpdateBeforeExtraction": True,
                    "SURequireSignedFeed": True, "SmokeLogPath": str(log),
                    "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
                }
                (contents / "Info.plist").write_bytes(plistlib.dumps(info))
                run(["xattr", "-cr", app])
                run(["codesign", "--force", "--sign", "-", app])
                run(["codesign", "--verify", "--deep", "--strict", app])
            archive = case / "update.zip"
            run(["ditto", "-c", "-k", "--keepParent", update, archive])
            signature = run([signer, "--account", options.account, "-p", archive])
            ET.register_namespace("sparkle", SPARKLE_NS)
            rss = ET.Element("rss", version="2.0")
            channel = ET.SubElement(rss, "channel")
            ET.SubElement(channel, "title").text = "Disposable updater smoke fixture"
            item = ET.SubElement(channel, "item")
            ET.SubElement(item, "title").text = "UpdaterSmoke 2.0"
            ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = "2"
            ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = "2.0"
            ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = "26.0.0"
            ET.SubElement(item, "enclosure", {
                "url": url + "/update.zip", "length": str(archive.stat().st_size),
                "type": "application/octet-stream", f"{{{SPARKLE_NS}}}edSignature": signature,
            })
            feed = case / "appcast.xml"
            ET.ElementTree(rss).write(feed, encoding="utf-8", xml_declaration=True)
            run([signer, "--account", options.account, feed])
            run([signer, "--account", options.account, "--verify", feed])
            if scenario == "tampered-feed":
                # Keep XML valid so the real signature check is exercised.
                feed.write_bytes(feed.read_bytes().replace(b"UpdaterSmoke 2.0", b"UpdaterSmoke 9.9"))
            elif scenario == "tampered-archive":
                # Preserve size and ZIP structure, invalidate only its signed bytes.
                data = bytearray(archive.read_bytes())
                data[len(data) // 2] ^= 1
                archive.write_bytes(data)
            with (case / "process.log").open("w") as process_log:
                process = subprocess.Popen([target / "Contents/MacOS/UpdaterSmoke"],
                                           stdout=process_log, stderr=subprocess.STDOUT,
                                           start_new_session=True)
                processes.append(process)
                deadline = time.monotonic() + options.timeout
                events = ""
                while time.monotonic() < deadline:
                    events = log.read_text() if log.exists() else ""
                    if "relaunched-new-version" in events or "error:" in events or "not-found:" in events:
                        break
                    time.sleep(0.2)
                version = plistlib.loads((target / "Contents/Info.plist").read_bytes())["CFBundleVersion"]
                shutil.copy2(log, report_dir / f"{scenario}.log") if log.exists() else None
                shutil.copy2(case / "process.log", report_dir / f"{scenario}-process.log")
                if scenario == "install":
                    require(version == "2" and "relaunched-new-version" in events, events or "No updater events")
                    require("found:2:signature-status=1" in events, events)
                    require(all(event in events for event in ("download-started", "extracting", "ready-to-install", "termination-request")),
                            "Sparkle did not complete the normal download, install and termination path: " + events)
                else:
                    require(version == "1" and "relaunched-new-version" not in events, events)
                    # 3002 is SUValidationError in Sparkle 2.10: mismatched EdDSA bytes.
                    require("error:" in events and "SUSparkleErrorDomain:3002" in events, events)
                    require("ready-to-install" not in events, "Tampered update reached installation: " + events)
                    if scenario == "tampered-feed":
                        require("found:" not in events and "download-started" not in events, events)
                    else:
                        require("download-started" in events, events)
                results.append({"scenario": scenario, "passed": True, "installedVersion": version})
                print(f"PASS {scenario}: installed version {version}", flush=True)
                if process.poll() is None:
                    process.wait(timeout=10)
        success = True
        (report_dir / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        print(f"All Sparkle smoke checks passed. Logs: {report_dir}", flush=True)
    finally:
        server.shutdown()
        for process in processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
        for domain in domains:
            subprocess.run(["defaults", "delete", domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            cache = Path.home() / "Library/Caches" / domain
            if cache.is_dir():
                shutil.rmtree(cache)
        if success and not options.keep:
            shutil.rmtree(work)
        else:
            print(f"Fixtures retained for inspection: {work}", flush=True)


if __name__ == "__main__":
    main()
