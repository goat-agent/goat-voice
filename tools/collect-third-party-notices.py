#!/usr/bin/env python3
import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

RULE = "=" * 80
SUBRULE = "-" * 80


@dataclass(frozen=True)
class LicenseRef:
    checkout: str | None
    relpath: str
    label: str
    extract: str = "file"


@dataclass(frozen=True)
class Component:
    name: str
    pin: str | None
    source: str
    shipped: str
    licenses: tuple[LicenseRef, ...]
    revision: str | None = None
    attribution: tuple[str, ...] = ()


COMPONENTS: tuple[Component, ...] = (
    Component(
        name="Sparkle",
        pin="sparkle",
        source="https://github.com/sparkle-project/Sparkle",
        shipped="Sparkle.framework embedded in the app bundle (Sparkle, Autoupdate, "
                "Updater.app, Downloader.xpc, Installer.xpc). The license below also "
                "covers third-party code vendored by Sparkle: bsdiff 4.3, sais-lite, "
                "orlp/ed25519, and SUSignatureVerifier.",
        licenses=(LicenseRef("sparkle", "LICENSE", "LICENSE"),),
    ),
    Component(
        name="Argmax OSS (WhisperKit, ArgmaxCore)",
        pin="argmax-oss-swift",
        source="https://github.com/argmaxinc/argmax-oss-swift",
        shipped="Statically linked Swift modules WhisperKit and ArgmaxCore in the "
                "GoatVoiceSTT XPC service binary.",
        licenses=(
            LicenseRef("argmax-oss-swift", "LICENSE", "LICENSE"),
            LicenseRef("argmax-oss-swift", "NOTICES", "NOTICES"),
        ),
    ),
    Component(
        name="MLX Audio for Swift",
        pin="mlx-audio-swift",
        source="https://github.com/Blaizzy/mlx-audio-swift",
        shipped="Statically linked Swift modules MLXAudioSTT, MLXAudioCore, "
                "MLXAudioCodecs, and MLXAudioVAD in the GoatVoiceSTT XPC service binary.",
        licenses=(LicenseRef("mlx-audio-swift", "LICENSE", "LICENSE"),),
    ),
    Component(
        name="MLX Swift LM",
        pin="mlx-swift-lm",
        source="https://github.com/ml-explore/mlx-swift-lm",
        shipped="Statically linked Swift modules MLXLLM and MLXLMCommon in the "
                "GoatVoiceSTT XPC service binary.",
        licenses=(LicenseRef("mlx-swift-lm", "LICENSE", "LICENSE"),),
    ),
    Component(
        name="MLX Swift",
        pin="mlx-swift",
        source="https://github.com/ml-explore/mlx-swift",
        shipped="Statically linked Swift modules MLX, MLXNN, MLXFast, and "
                "MLXOptimizers plus the Cmlx C++ target and its compiled "
                "default.metallib shader library in the GoatVoiceSTT XPC service.",
        licenses=(LicenseRef("mlx-swift", "LICENSE", "LICENSE"),),
    ),
    Component(
        name="MLX (C++ core)",
        pin=None,
        source="https://github.com/ml-explore/mlx",
        shipped="Vendored inside mlx-swift (Source/Cmlx/mlx) and compiled into the "
                "GoatVoiceSTT XPC service binary, including Metal kernels shipped in "
                "default.metallib.",
        revision="vendored in mlx-swift",
        licenses=(LicenseRef("mlx-swift", "Source/Cmlx/mlx/LICENSE", "LICENSE"),),
    ),
    Component(
        name="mlx-c",
        pin=None,
        source="https://github.com/ml-explore/mlx-c",
        shipped="Vendored inside mlx-swift (Source/Cmlx/mlx-c) and compiled into the "
                "GoatVoiceSTT XPC service binary.",
        revision="vendored in mlx-swift",
        licenses=(LicenseRef("mlx-swift", "Source/Cmlx/mlx-c/LICENSE", "LICENSE"),),
    ),
    Component(
        name="{fmt}",
        pin=None,
        source="https://github.com/fmtlib/fmt",
        shipped="Vendored inside mlx-swift (Source/Cmlx/fmt, upstream tag 12.1.0 per "
                "mlx-swift Source/Cmlx/vendor-README.md) and compiled into the "
                "GoatVoiceSTT XPC service binary.",
        revision="12.1.0, vendored in mlx-swift",
        licenses=(LicenseRef("mlx-swift", "Source/Cmlx/fmt/LICENSE", "LICENSE"),),
    ),
    Component(
        name="nlohmann/json",
        pin=None,
        source="https://github.com/nlohmann/json",
        shipped="Vendored inside mlx-swift (Source/Cmlx/json, upstream release "
                "v3.11.3 per mlx-swift Source/Cmlx/vendor-README.md); header-only "
                "library compiled into the GoatVoiceSTT XPC service binary.",
        revision="3.11.3, vendored in mlx-swift",
        licenses=(LicenseRef("mlx-swift", "Source/Cmlx/json/LICENSE.MIT", "LICENSE.MIT"),),
    ),
    Component(
        name="metal-cpp",
        pin=None,
        source="https://developer.apple.com/metal/cpp/",
        shipped="Vendored inside mlx-swift (Source/Cmlx/metal-cpp, from Apple's "
                "metal-cpp_macOS15_iOS18-beta distribution with mlx-swift's "
                "metal-cpp.patch applied, per Source/Cmlx/vendor-README.md); "
                "header-only library compiled into the GoatVoiceSTT XPC service binary.",
        revision="metal-cpp_macOS15_iOS18-beta + metal-cpp.patch, vendored in mlx-swift",
        licenses=(LicenseRef("mlx-swift", "Source/Cmlx/metal-cpp/LICENSE.txt", "LICENSE.txt"),),
    ),
    Component(
        name="PocketFFT",
        pin=None,
        source="https://gitlab.mpcdf.mpg.de/mtr/pocketfft",
        shipped="Vendored inside mlx-swift (Source/Cmlx/mlx/mlx/3rdparty/pocketfft.h); "
                "header-only library compiled into the GoatVoiceSTT XPC service "
                "binary via MLX's FFT implementation.",
        revision="vendored in mlx-swift",
        licenses=(LicenseRef(
            "mlx-swift", "Source/Cmlx/mlx/mlx/3rdparty/pocketfft.h",
            "License text from the pocketfft.h file header", extract="cblock"),),
    ),
    Component(
        name="swift-transformers",
        pin="swift-transformers",
        source="https://github.com/huggingface/swift-transformers",
        shipped="Statically linked Swift modules Hub, Tokenizers, Models, and "
                "Generation in the GoatVoiceSTT XPC service binary, plus the "
                "swift-transformers_Hub resource bundle (gpt2_tokenizer_config.json, "
                "t5_tokenizer_config.json).",
        licenses=(LicenseRef("swift-transformers", "LICENSE", "LICENSE"),),
    ),
    Component(
        name="swift-huggingface",
        pin="swift-huggingface",
        source="https://github.com/huggingface/swift-huggingface",
        shipped="Statically linked Swift module HuggingFace in the GoatVoiceSTT XPC "
                "service binary.",
        licenses=(LicenseRef("swift-huggingface", "LICENSE", "LICENSE"),),
    ),
    Component(
        name="swift-jinja",
        pin="swift-jinja",
        source="https://github.com/huggingface/swift-jinja",
        shipped="Statically linked Swift module Jinja in the GoatVoiceSTT XPC "
                "service binary.",
        licenses=(LicenseRef("swift-jinja", "LICENSE", "LICENSE"),),
    ),
    Component(
        name="Swift Collections",
        pin="swift-collections",
        source="https://github.com/apple/swift-collections",
        shipped="Statically linked Swift modules OrderedCollections and "
                "InternalCollectionsUtilities in the GoatVoiceSTT XPC service binary.",
        licenses=(LicenseRef("swift-collections", "LICENSE.txt", "LICENSE.txt"),),
    ),
    Component(
        name="Swift Crypto",
        pin="swift-crypto",
        source="https://github.com/apple/swift-crypto",
        shipped="Statically linked Swift module Crypto in the GoatVoiceSTT XPC "
                "service binary, backed by CryptoKit on macOS.",
        licenses=(
            LicenseRef("swift-crypto", "LICENSE.txt", "LICENSE.txt"),
            LicenseRef("swift-crypto", "NOTICE.txt", "NOTICE.txt"),
        ),
    ),
    Component(
        name="Swift Numerics",
        pin="swift-numerics",
        source="https://github.com/apple/swift-numerics",
        shipped="Statically linked Swift modules Numerics, RealModule, ComplexModule, "
                "and _NumericsShims in the GoatVoiceSTT XPC service binary.",
        licenses=(LicenseRef("swift-numerics", "LICENSE.txt", "LICENSE.txt"),),
    ),
    Component(
        name="EventSource",
        pin="eventsource",
        source="https://github.com/mattt/EventSource",
        shipped="Statically linked Swift module EventSource in the GoatVoiceSTT XPC "
                "service binary.",
        licenses=(LicenseRef("eventsource", "LICENSE.md", "LICENSE.md"),),
    ),
    Component(
        name="yyjson",
        pin="yyjson",
        source="https://github.com/ibireme/yyjson",
        shipped="Statically linked C library in the GoatVoiceSTT XPC service binary "
                "(dependency of swift-transformers).",
        licenses=(LicenseRef("yyjson", "LICENSE", "LICENSE"),),
    ),
)

NOT_DISTRIBUTED = {
    "swift-argument-parser": "used only by unshipped example/CLI targets",
    "swift-asn1": "not referenced by any shipped target",
    "swift-syntax": "compile-time macro/tooling support only; not linked",
}

QWEN_APACHE_REF = LicenseRef(
    "swift-crypto", "LICENSE.txt",
    "Apache License, Version 2.0 (canonical text)")


def load_pins(resolved_path: Path) -> dict[str, dict[str, str]]:
    try:
        document = json.loads(resolved_path.read_text())
    except (ValueError, OSError) as error:
        raise RuntimeError(f"cannot parse {resolved_path}: {error}")
    pins: dict[str, dict[str, str]] = {}
    for entry in document.get("pins", []):
        identity = entry.get("identity")
        state = entry.get("state") or {}
        revision = state.get("revision")
        if not identity or not revision:
            raise RuntimeError(f"pin without identity or revision in {resolved_path}")
        pins[identity] = {
            "location": entry.get("location", ""),
            "revision": revision,
            "version": state.get("version") or state.get("branch") or "",
        }
    return pins


def checkout_name(location: str) -> str:
    name = location.rstrip("/").rsplit("/", 1)[-1]
    return name[:-4] if name.endswith(".git") else name


def extract_text(path: Path, mode: str) -> str:
    try:
        raw = path.read_bytes()
    except OSError as error:
        raise RuntimeError(f"required license file missing or unreadable: {path}: {error}")
    text = raw.decode("utf-8")
    if mode == "file":
        return text.strip("\n")
    if mode == "cblock":
        match = re.match(r"\s*/\*(.*?)\*/", text, re.S)
        if match is None:
            raise RuntimeError(f"no leading C comment block found in {path}")
        return match.group(1).strip("\n")
    raise RuntimeError(f"unknown extraction mode: {mode}")


def qwen_component(root: Path, catalog_path: Path) -> Component:
    try:
        catalog = json.loads(catalog_path.read_text())
    except (ValueError, OSError) as error:
        raise RuntimeError(f"cannot parse model catalog {catalog_path}: {error}")
    bundled = None
    upstream = None
    for manifest in catalog:
        for artifact in manifest.get("artifacts", []):
            url = str(artifact.get("downloadURL", ""))
            if url == "bundle://Models/qwen3-tokenizer.json":
                bundled = artifact
            match = re.match(
                r"^https://huggingface\.co/([^/]+/[^/]+)/resolve/([0-9a-f]{40})/",
                url)
            if match and match.group(1) == "mlx-community/Qwen3-ASR-1.7B-8bit":
                upstream = match
    if bundled is None or upstream is None:
        raise RuntimeError(
            f"cannot determine qwen3 tokenizer provenance from {catalog_path}")
    tokenizer_path = root / "Resources" / "Models" / "qwen3-tokenizer.json"
    if not tokenizer_path.is_file():
        raise RuntimeError(f"bundled tokenizer file missing: {tokenizer_path}")
    revision = f"mlx-community/Qwen3-ASR-1.7B-8bit@{upstream.group(2)}"
    attribution = (
        "Resources/Models/qwen3-tokenizer.json is a Hugging Face format "
        "tokenizer.json synthesized from the vocab.json, merges.txt, and "
        "tokenizer_config.json files of the Qwen3-ASR-1.7B model (QwenLM / "
        "Alibaba Group). The upstream model and its mlx-community conversion are "
        "licensed under the Apache License, Version 2.0, as declared by the "
        "licensing metadata of the Qwen/Qwen3-ASR-1.7B, "
        "mlx-community/Qwen3-ASR-1.7B-8bit, and QwenLM/Qwen3-ASR repositories.",
        f"Bundled file sha256: {bundled.get('sha256Hex')} "
        f"({bundled.get('byteCount')} bytes).",
    )
    return Component(
        name="Qwen3-ASR-1.7B tokenizer data",
        pin=None,
        source="https://huggingface.co/Qwen/Qwen3-ASR-1.7B",
        shipped="Bundled data file Contents/Resources/Models/qwen3-tokenizer.json "
                "in the app bundle.",
        revision=revision,
        attribution=attribution,
        licenses=(QWEN_APACHE_REF,),
    )


def render(components: list[Component], pins: dict[str, dict[str, str]],
           checkouts: Path, root: Path) -> str:
    out: list[str] = []
    out.append("Goat Voice Third-Party Notices")
    out.append(RULE)
    out.append("")
    out.append("Generated by tools/collect-third-party-notices.py from "
               "Package.resolved and the SwiftPM dependency checkouts. Do not "
               "edit by hand; regenerate with:")
    out.append("")
    out.append("    python3 tools/collect-third-party-notices.py")
    out.append("")
    out.append("Goat Voice itself is licensed under the MIT License (see "
               "LICENSE). The entries below are third-party software and data "
               "redistributed inside the Goat Voice application bundle, either "
               "statically linked into its executables or shipped as binary "
               "frameworks, resource bundles, or data files. Upstream license "
               "and notice texts are reproduced verbatim. Model weights are "
               "downloaded on demand at runtime and are not part of the "
               "distributed bundle.")
    out.append("")
    out.append("Resolved SwiftPM packages not distributed in the bundle: "
               + ", ".join(sorted(NOT_DISTRIBUTED)) + ".")
    for component in components:
        pin = pins.get(component.pin) if component.pin else None
        if component.pin and pin is None:
            raise RuntimeError(
                f"no pin found in Package.resolved for {component.pin}")
        if component.pin:
            revision = pin["revision"]
            if pin["version"]:
                revision = f"{pin['version']} ({revision})"
        else:
            revision = component.revision or "not pinned"
        out.append("")
        out.append(RULE)
        out.append(component.name)
        out.append(RULE)
        out.append(f"Source: {component.source}")
        out.append(f"Revision: {revision}")
        out.append(f"Shipped as: {component.shipped}")
        for line in component.attribution:
            out.append("")
            out.append(line)
        for license_ref in component.licenses:
            if license_ref.checkout is not None:
                host = pins.get(license_ref.checkout)
                if host is None:
                    raise RuntimeError(
                        f"no pin found for license host {license_ref.checkout}")
                base = checkouts / checkout_name(host["location"])
            else:
                base = root
            text = extract_text(base / license_ref.relpath, license_ref.extract)
            out.append("")
            out.append(SUBRULE)
            out.append(license_ref.label)
            out.append(SUBRULE)
            out.append(text)
    return "\n".join(out) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Generate THIRD_PARTY_NOTICES.txt for the distributed bundle.")
    parser.add_argument("--out", type=Path,
                        default=ROOT / "THIRD_PARTY_NOTICES.txt")
    parser.add_argument("--package-resolved", type=Path,
                        default=ROOT / "Package.resolved")
    parser.add_argument("--checkouts", type=Path, default=ROOT / ".build" / "checkouts")
    parser.add_argument("--catalog", type=Path,
                        default=ROOT / "Resources" / "Models" / "catalog.json")
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--check", action="store_true",
                        help="verify --out matches generated output without writing")
    args = parser.parse_args(argv)
    pins = load_pins(args.package_resolved)
    components: list[Component] = list(COMPONENTS)
    components.append(qwen_component(args.root, args.catalog))
    covered = {c.pin for c in components if c.pin} | set(NOT_DISTRIBUTED)
    missing = sorted(set(pins) - covered)
    if missing:
        raise RuntimeError(
            "pins not classified as distributed or not-distributed: "
            + ", ".join(missing))
    text = render(components, pins, args.checkouts, args.root)
    if args.check:
        existing = args.out.read_text() if args.out.is_file() else None
        if existing != text:
            print(f"notices out of date: {args.out}; regenerate with "
                  "tools/collect-third-party-notices.py", file=sys.stderr)
            return 1
        return 0
    args.out.write_text(text)
    print(f"wrote {args.out} ({len(text)} bytes)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError) as error:
        sys.exit(f"notice collection failed: {error}")
