import argparse
import base64
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location("release", Path(__file__).with_name("release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def gh(*arguments, payload=None, allow_missing=False):
    command = ["gh", *arguments]
    if payload is not None:
        command += ["--input", "-"]
    result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                            text=True, capture_output=True)
    if result.returncode:
        if allow_missing and "HTTP 404" in result.stderr:
            return None
        raise RuntimeError("GitHub operation failed: " + result.stderr.strip())
    return json.loads(result.stdout) if result.stdout.strip() else None


def feed_build(xml):
    root = ET.fromstring(xml)
    versions = []
    for enclosure in root.findall("./channel/item/enclosure"):
        raw = enclosure.get(f"{{{release.SPARKLE}}}version", "")
        if not raw.isdecimal():
            raise ValueError("Published feed has an invalid build number")
        versions.append(int(raw))
    return max(versions, default=0)


def combine_feeds(new, previous):
    root = ET.fromstring(new)
    channel = root.find("channel")
    if channel is None:
        raise ValueError("Missing feed channel")
    if previous:
        if feed_build(previous) >= feed_build(new):
            raise ValueError("Release build must be newer than the published update feed")
        for item in ET.fromstring(previous).findall("./channel/item")[:19]:
            channel.append(copy.deepcopy(item))
    ET.indent(root)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True) + b"\n"


def verify_download(url, expected_digest):
    for attempt in range(5):
        try:
            digest = hashlib.sha256()
            with urlopen(Request(url, headers={"User-Agent": "GoatVoice-Release"}), timeout=60) as response:
                for chunk in iter(lambda: response.read(1024 * 1024), b""):
                    digest.update(chunk)
            if digest.hexdigest() != expected_digest:
                raise ValueError("Published download checksum mismatch")
            return
        except (HTTPError, URLError):
            if attempt == 4:
                raise
            time.sleep(2 ** attempt)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    config = release.configuration()
    repo = config["repository"]
    if os.environ.get("GITHUB_REPOSITORY", repo) != repo:
        raise ValueError("Release repository does not match configuration")
    directory = args.directory
    archive = directory / release.archive_name(config)
    metadata = json.loads((directory / "release-info.json").read_text())
    if metadata["version"] != config["version"] or metadata["build"] != config["build"]:
        raise ValueError("Artifact version mismatch")
    source_commit = gh("api", f"repos/{repo}/commits/{release.tag(config)}")["sha"]
    if source_commit != metadata["commit"]:
        raise ValueError("Release tag no longer matches the built commit")
    previous_ref = gh("api", f"repos/{repo}/git/ref/heads/updates", allow_missing=True)
    previous_xml = None
    if previous_ref:
        content = gh("api", f"repos/{repo}/contents/appcast.xml?ref=updates")
        previous_xml = base64.b64decode(content["content"])
    new_feed = (directory / "appcast.xml").read_bytes()
    existing = gh("api", f"repos/{repo}/releases/tags/{release.tag(config)}", allow_missing=True)
    if previous_xml and feed_build(previous_xml) == config["build"]:
        previous_item = ET.fromstring(previous_xml).find("./channel/item/enclosure")
        new_item = ET.fromstring(new_feed).find("./channel/item/enclosure")
        if not existing or existing["draft"] or previous_item.attrib != new_item.attrib:
            raise ValueError("Published build already exists with different artifacts")
        with archive.open("rb") as source:
            digest = hashlib.file_digest(source, "sha256").hexdigest()
        verify_download(new_item.attrib["url"], digest)
        print("Release and update feed are already published")
        return
    feed = combine_feeds(new_feed, previous_xml)
    if existing and not existing["draft"]:
        published = existing
    else:
        if existing:
            draft = existing
        else:
            draft = gh("api", f"repos/{repo}/releases", "--method", "POST", payload={
                "tag_name": release.tag(config), "target_commitish": source_commit,
                "name": "Goat Voice " + config["version"], "draft": True,
                "prerelease": config["prerelease"], "generate_release_notes": True,
                "body": "Apple Silicon macOS app. This public beta is ad-hoc signed and is not notarized by Apple. "
                        "macOS may require explicit approval on first launch. Updates are signed with Sparkle Ed25519. "
                        "Model weights are downloaded separately in Settings; audio stays local.",
            })
        assets = [archive, directory / "SHA256SUMS", directory / "appcast.xml", directory / "release-info.json"]
        subprocess.run(["gh", "release", "upload", release.tag(config), *map(str, assets),
                        "--repo", repo, "--clobber"], check=True)
        published = gh("api", f"repos/{repo}/releases/{draft['id']}", "--method", "PATCH",
                       payload={"draft": False, "make_latest": "false" if config["prerelease"] else "true"})
    enclosure = ET.fromstring(feed).find("./channel/item/enclosure")
    with archive.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    verify_download(enclosure.attrib["url"], digest)
    tree = gh("api", f"repos/{repo}/git/trees", "--method", "POST", payload={"tree": [{
        "path": "appcast.xml", "mode": "100644", "type": "blob", "content": feed.decode(),
    }]})
    parents = [previous_ref["object"]["sha"]] if previous_ref else []
    commit = gh("api", f"repos/{repo}/git/commits", "--method", "POST", payload={
        "message": "Publish Goat Voice " + config["version"] + " update feed",
        "tree": tree["sha"], "parents": parents,
    })
    if previous_ref:
        gh("api", f"repos/{repo}/git/refs/heads/updates", "--method", "PATCH",
           payload={"sha": commit["sha"], "force": False})
    else:
        gh("api", f"repos/{repo}/git/refs", "--method", "POST",
           payload={"ref": "refs/heads/updates", "sha": commit["sha"]})
    public_feed = f"https://raw.githubusercontent.com/{repo}/{commit['sha']}/appcast.xml"
    verify_download(public_feed, hashlib.sha256(feed).hexdigest())
    print("Published release: " + published["html_url"])
    print("Update feed published after archive availability and checksum verification")


if __name__ == "__main__":
    main()
