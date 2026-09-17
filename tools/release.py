import argparse
import base64
import binascii
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from datetime import datetime, timezone
from email.utils import format_datetime
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def configuration(path=ROOT / "release.json"):
    config = json.loads(path.read_text())
    if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", config["version"]):
        raise ValueError("Release version must be major.minor.patch")
    if type(config["build"]) is not int or config["build"] < 1:
        raise ValueError("Build must be a positive integer")
    if type(config["prerelease"]) is not bool:
        raise ValueError("Prerelease must be a boolean")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", config["repository"]):
        raise ValueError("Invalid repository")
    expected = f"https://raw.githubusercontent.com/{config['repository']}/updates/appcast.xml"
    if config["feedURL"] != expected:
        raise ValueError("Update feed must match the release repository")
    try:
        key = base64.b64decode(config["publicKey"], validate=True)
    except (binascii.Error, ValueError) as error:
        raise ValueError("Invalid update public key") from error
    if len(key) != 32:
        raise ValueError("Update public key must contain 32 bytes")
    return config


def tag(config):
    return "v" + config["version"]


def archive_name(config):
    return f"GoatVoice-{config['version']}-arm64.dmg"


def configure_bundle(bundle, config):
    paths = [bundle / "Contents/Info.plist",
             bundle / "Contents/XPCServices/GoatVoiceSTT.xpc/Contents/Info.plist"]
    for path in paths:
        with path.open("rb") as source:
            values = plistlib.load(source)
        values["CFBundleShortVersionString"] = config["version"]
        values["CFBundleVersion"] = str(config["build"])
        if path == paths[0]:
            values["SUFeedURL"] = config["feedURL"]
            values["SUPublicEDKey"] = config["publicKey"]
            values["SUEnableAutomaticChecks"] = False
            values["SUAutomaticallyUpdate"] = False
        with path.open("wb") as destination:
            plistlib.dump(values, destination, sort_keys=False)


def validate_bundle(bundle, config):
    for path in [bundle / "Contents/Info.plist",
                 bundle / "Contents/XPCServices/GoatVoiceSTT.xpc/Contents/Info.plist"]:
        values = plistlib.loads(path.read_bytes())
        if (values.get("CFBundleShortVersionString"), values.get("CFBundleVersion")) != (
                config["version"], str(config["build"])):
            raise ValueError("Bundle version does not match release.json")
    app = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    if app.get("SUFeedURL") != config["feedURL"] or app.get("SUPublicEDKey") != config["publicKey"]:
        raise ValueError("Bundle update configuration does not match release.json")
    for name in ["LICENSE", "THIRD_PARTY_NOTICES.txt"]:
        if not (bundle / "Contents/Resources" / name).is_file():
            raise ValueError("Missing bundled license notices")
    return app["LSMinimumSystemVersion"]


def appcast(config, archive, signature, minimum_system, published_at=None):
    if archive.name != archive_name(config) or not archive.is_file():
        raise ValueError("Release archive name does not match its version")
    try:
        decoded = base64.b64decode(signature, validate=True)
    except (binascii.Error, ValueError) as error:
        raise ValueError("Invalid signature") from error
    if len(decoded) != 64:
        raise ValueError("Invalid signature length")
    if not re.fullmatch(r"\d+\.\d+(\.\d+)?", minimum_system):
        raise ValueError("Invalid minimum macOS version")
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "Goat Voice"
    ET.SubElement(channel, "link").text = f"https://github.com/{config['repository']}"
    ET.SubElement(channel, "description").text = "Goat Voice updates"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = "Goat Voice " + config["version"]
    ET.SubElement(item, "pubDate").text = format_datetime(published_at or datetime.now(timezone.utc))
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = minimum_system
    ET.SubElement(item, "enclosure", {
        "url": f"https://github.com/{config['repository']}/releases/download/{tag(config)}/{archive.name}",
        "length": str(archive.stat().st_size),
        "type": "application/octet-stream",
        f"{{{SPARKLE}}}version": str(config["build"]),
        f"{{{SPARKLE}}}shortVersionString": config["version"],
        f"{{{SPARKLE}}}edSignature": signature,
    })
    ET.indent(root)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True) + b"\n"


def sign_release(directory, signer, verifier, config):
    private_key = os.environ.get("SPARKLE_PRIVATE_KEY")
    if not private_key:
        raise ValueError("SPARKLE_PRIVATE_KEY is required")
    archive = directory / archive_name(config)
    if not archive.is_file():
        raise ValueError("Release archive is missing")
    metadata = json.loads((directory / "release-info.json").read_text())
    if metadata["version"] != config["version"] or metadata["build"] != config["build"]:
        raise ValueError("Artifact metadata does not match release.json")
    environment = {key: value for key, value in os.environ.items() if key != "SPARKLE_PRIVATE_KEY"}
    result = subprocess.run([str(signer), "--ed-key-file", "-", "-p", str(archive)],
                            input=private_key + "\n", text=True, capture_output=True, env=environment)
    if result.returncode:
        raise ValueError("Sparkle signing failed")
    signature = result.stdout.strip()
    verified = subprocess.run([str(verifier), config["publicKey"], signature, str(archive)],
                              capture_output=True, env=environment)
    if verified.returncode:
        raise ValueError("Archive signature does not match the embedded public key")
    (directory / "appcast.xml").write_bytes(appcast(config, archive, signature, metadata["minimumSystemVersion"]))
    names = [archive.name, "appcast.xml", "release-info.json"]
    lines = []
    for name in names:
        with (directory / name).open("rb") as source:
            digest = hashlib.file_digest(source, "sha256").hexdigest()
        lines.append(f"{digest}  {name}\n")
    (directory / "SHA256SUMS").write_text("".join(lines))
    print("Release signature verified against the app public key")


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("metadata")
    validate = commands.add_parser("validate-tag")
    validate.add_argument("tag")
    configure = commands.add_parser("configure-bundle")
    configure.add_argument("bundle", type=Path)
    package = commands.add_parser("artifact-metadata")
    package.add_argument("bundle", type=Path)
    package.add_argument("directory", type=Path)
    sign = commands.add_parser("sign")
    sign.add_argument("directory", type=Path)
    sign.add_argument("signer", type=Path)
    sign.add_argument("verifier", type=Path)
    args = parser.parse_args()
    config = configuration()
    if args.command == "metadata":
        print(json.dumps(dict(config, tag=tag(config), archive=archive_name(config))))
    elif args.command == "validate-tag":
        if args.tag != tag(config):
            raise ValueError("Tag does not match release.json")
        print("Release tag validated")
    elif args.command == "configure-bundle":
        configure_bundle(args.bundle, config)
    elif args.command == "artifact-metadata":
        dirty = subprocess.check_output(["git", "status", "--porcelain"], text=True)
        if dirty.strip():
            raise ValueError("Commit source changes before preparing release artifacts")
        minimum = validate_bundle(args.bundle, config)
        revision = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
        args.directory.mkdir(parents=True, exist_ok=True)
        (args.directory / "release-info.json").write_text(json.dumps({
            "version": config["version"], "build": config["build"], "commit": revision,
            "minimumSystemVersion": minimum, "architecture": "arm64", "notarized": False,
        }, indent=2) + "\n")
    else:
        sign_release(args.directory, args.signer, args.verifier, config)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError) as error:
        print(f"Release preparation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
