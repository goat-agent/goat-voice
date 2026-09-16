#!/usr/bin/env python3
import argparse
import hashlib
import json
import re
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

HF_HOST = "https://huggingface.co"
CHUNK_BYTES = 1 << 20
HTTP_TIMEOUT_SECONDS = 30
DEFAULT_MAX_FETCH_BYTES = 32 * 1024 * 1024
RESOLVE_URL_PATTERN = re.compile(
    rf"^{re.escape(HF_HOST)}/(.+)/resolve/([0-9a-f]{{40}})/.+$")
QWEN_TOKENIZER_BUNDLE_RESOURCE = "Models/qwen3-tokenizer.json"
QWEN_PRE_TOKENIZER_PATTERN = (
    "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?\\p{L}+|"
    "\\p{N}{1,3}| ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+"
)


@dataclass(frozen=True)
class TreeEntry:
    path: str
    size: int
    lfs_sha256: str | None


@dataclass(frozen=True)
class RepoSource:
    repo: str
    prefix: str = ""
    include: frozenset[str] | None = None
    strip_prefix: bool = False


@dataclass(frozen=True)
class GeneratedTokenizer:
    bundle_resource: str
    relative_path: str
    input_paths: tuple[str, ...]


@dataclass(frozen=True)
class ModelSpec:
    model_id: str
    format: str
    sources: tuple[RepoSource, ...]
    generated_tokenizer: GeneratedTokenizer | None = None


MODEL_SPECS: tuple[ModelSpec, ...] = (
    ModelSpec(
        model_id="qwen3-asr-1.7b",
        format="mlx-safetensors-8bit",
        sources=(
            RepoSource(
                repo="mlx-community/Qwen3-ASR-1.7B-8bit",
                include=frozenset({
                    "chat_template.json",
                    "config.json",
                    "generation_config.json",
                    "merges.txt",
                    "model.safetensors",
                    "model.safetensors.index.json",
                    "preprocessor_config.json",
                    "tokenizer_config.json",
                    "vocab.json",
                }),
            ),
        ),
        generated_tokenizer=GeneratedTokenizer(
            bundle_resource=QWEN_TOKENIZER_BUNDLE_RESOURCE,
            relative_path="tokenizer.json",
            input_paths=("vocab.json", "merges.txt", "tokenizer_config.json"),
        ),
    ),
    ModelSpec(
        model_id="whisper-large-v3-turbo",
        format="coreml-mlmodelc",
        sources=(
            RepoSource(
                repo="argmaxinc/whisperkit-coreml",
                prefix="openai_whisper-large-v3-v20240930_turbo",
                strip_prefix=True,
            ),
            RepoSource(
                repo="openai/whisper-large-v3",
                include=frozenset({"tokenizer.json", "tokenizer_config.json"}),
            ),
        ),
    ),
)


def api_get(url: str) -> tuple[bytes, dict[str, str]]:
    request = urllib.request.Request(url, headers={"User-Agent": "goat-voice-catalog/1.0"})
    with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
        return response.read(), dict(response.headers.items())


def api_json(url: str) -> object:
    body, _ = api_get(url)
    return json.loads(body)


def resolve_head(repo: str) -> str:
    info = api_json(f"{HF_HOST}/api/models/{repo}")
    if not isinstance(info, dict) or not isinstance(info.get("sha"), str):
        raise RuntimeError(f"Cannot resolve default revision for {repo}")
    return info["sha"]


def list_tree(repo: str, revision: str, prefix: str) -> list[TreeEntry]:
    url = f"{HF_HOST}/api/models/{repo}/tree/{revision}"
    if prefix:
        url += f"/{prefix}"
    url += "?recursive=true"
    entries: list[TreeEntry] = []
    while True:
        body, headers = api_get(url)
        page = json.loads(body)
        if not isinstance(page, list):
            raise RuntimeError(f"Unexpected tree response for {repo} at {prefix or '/'}")
        for item in page:
            if item.get("type") != "file":
                continue
            lfs = item.get("lfs")
            entries.append(TreeEntry(
                path=item["path"],
                size=int(item["size"]),
                lfs_sha256=lfs["oid"] if isinstance(lfs, dict) else None,
            ))
        link = headers.get("Link", "")
        next_url = next(
            (part.split(";")[0].strip().strip("<>") for part in link.split(",")
             if 'rel="next"' in part),
            None,
        )
        if next_url is None:
            return entries
        url = next_url


def bounded_fetch(url: str, max_bytes: int, expected_size: int) -> bytes:
    request = urllib.request.Request(url, headers={
        "User-Agent": "goat-voice-catalog/1.0",
        "Accept-Encoding": "identity",
    })
    with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
        declared = response.headers.get("Content-Length")
        if declared is not None and int(declared) > max_bytes:
            raise RuntimeError(f"Refusing oversized fetch ({declared} bytes): {url}")
        buffer = bytearray()
        while True:
            chunk = response.read(min(CHUNK_BYTES, max_bytes - len(buffer) + 1))
            if not chunk:
                break
            buffer.extend(chunk)
            if len(buffer) > max_bytes:
                raise RuntimeError(f"Fetch exceeded {max_bytes} bytes: {url}")
    if len(buffer) != expected_size:
        raise RuntimeError(f"Size mismatch for {url}: tree={expected_size} fetched={len(buffer)}")
    return bytes(buffer)


def artifact_for(repo: str, revision: str, entry: TreeEntry, relative: str,
                 max_fetch: int) -> dict[str, object]:
    url = f"{HF_HOST}/{repo}/resolve/{revision}/{entry.path}"
    if entry.lfs_sha256 is not None:
        sha256 = entry.lfs_sha256
    else:
        data = bounded_fetch(url, max_fetch, entry.size)
        sha256 = hashlib.sha256(data).hexdigest()
    if len(sha256) != 64:
        raise RuntimeError(f"Non-SHA-256 digest for {entry.path}")
    return {
        "relativePath": relative,
        "downloadURL": url,
        "sha256Hex": sha256,
        "byteCount": entry.size,
    }


def pinned_revisions(catalog_path: Path) -> dict[str, str]:
    if not catalog_path.is_file():
        raise RuntimeError(f"--frozen requires an existing catalog: {catalog_path}")
    try:
        catalog = json.loads(catalog_path.read_text())
    except (ValueError, OSError) as error:
        raise RuntimeError(f"Cannot parse existing catalog {catalog_path}: {error}")
    pins: dict[str, str] = {}
    if not isinstance(catalog, list):
        raise RuntimeError(f"Existing catalog is not a manifest array: {catalog_path}")
    for manifest in catalog:
        for artifact in manifest.get("artifacts", []):
            match = RESOLVE_URL_PATTERN.match(str(artifact.get("downloadURL", "")))
            if match is None:
                continue
            repo, revision = match.group(1), match.group(2)
            previous = pins.setdefault(repo, revision)
            if previous != revision:
                raise RuntimeError(f"Conflicting pinned revisions for {repo} in {catalog_path}")
    return pins


def build_qwen_tokenizer_json(vocab: bytes, merges: bytes, tokenizer_config: bytes) -> bytes:
    vocab_map = json.loads(vocab)
    merge_lines = [
        line for line in merges.decode("utf-8").split("\n")
        if line and not line.startswith("#")
    ]
    config = json.loads(tokenizer_config)
    added_tokens = []
    for key, value in sorted(
        config.get("added_tokens_decoder", {}).items(), key=lambda pair: int(pair[0])
    ):
        added_tokens.append({
            "id": int(key),
            "content": value.get("content", ""),
            "single_word": bool(value.get("single_word", False)),
            "lstrip": bool(value.get("lstrip", False)),
            "rstrip": bool(value.get("rstrip", False)),
            "normalized": bool(value.get("normalized", False)),
            "special": bool(value.get("special", False)),
        })
    tokenizer = {
        "version": "1.0",
        "truncation": None,
        "padding": None,
        "added_tokens": added_tokens,
        "normalizer": {"type": "NFC"},
        "pre_tokenizer": {
            "type": "Sequence",
            "pretokenizers": [
                {
                    "type": "Split",
                    "pattern": {"Regex": QWEN_PRE_TOKENIZER_PATTERN},
                    "behavior": "Isolated",
                    "invert": False,
                },
                {
                    "type": "ByteLevel",
                    "add_prefix_space": False,
                    "trim_offsets": True,
                    "use_regex": False,
                },
            ],
        },
        "post_processor": None,
        "decoder": {
            "type": "ByteLevel",
            "add_prefix_space": True,
            "trim_offsets": True,
            "use_regex": True,
        },
        "model": {
            "type": "BPE",
            "dropout": None,
            "unk_token": None,
            "continuing_subword_prefix": "",
            "end_of_word_suffix": "",
            "fuse_unk": False,
            "byte_fallback": False,
            "vocab": vocab_map,
            "merges": merge_lines,
        },
    }
    return json.dumps(tokenizer, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":")).encode("utf-8")


def build_manifest(spec: ModelSpec, pins: dict[str, str] | None,
                   max_fetch: int) -> tuple[dict[str, object], bytes | None, dict[str, int]]:
    artifacts: list[dict[str, object]] = []
    version_parts: list[str] = [spec.format]
    stats = {"files": 0, "fetched": 0, "bytes": 0}
    resolved: dict[str, str] = {}
    bundled_payload: bytes | None = None
    for source in spec.sources:
        revision = resolved.get(source.repo)
        if revision is None:
            revision = (pins or {}).get(source.repo) or resolve_head(source.repo)
            resolved[source.repo] = revision
        entries = list_tree(source.repo, revision, source.prefix)
        if source.include is not None:
            wanted = set(source.include)
            selected = [e for e in entries if e.path in wanted]
            missing = wanted - {e.path for e in selected}
            if missing:
                raise RuntimeError(f"{source.repo} missing required files: {sorted(missing)}")
        else:
            selected = entries
        for entry in selected:
            if source.strip_prefix and source.prefix:
                if not entry.path.startswith(source.prefix + "/"):
                    raise RuntimeError(f"Unexpected path outside prefix: {entry.path}")
                relative = entry.path[len(source.prefix) + 1:]
            else:
                relative = entry.path
            artifacts.append(artifact_for(source.repo, revision, entry, relative, max_fetch))
            stats["files"] += 1
            stats["bytes"] += entry.size
            if entry.lfs_sha256 is None:
                stats["fetched"] += 1
        label = f"{source.repo}@{revision}"
        if source.prefix:
            label += f"/{source.prefix}"
        version_parts.append(label)
    if spec.generated_tokenizer is not None:
        generated = spec.generated_tokenizer
        source = spec.sources[0]
        revision = resolved[source.repo]
        base = f"{HF_HOST}/{source.repo}/resolve/{revision}"
        sizes = {e.path: e.size for e in list_tree(source.repo, revision, "")}
        missing_inputs = [p for p in generated.input_paths if p not in sizes]
        if missing_inputs:
            raise RuntimeError(
                f"{source.repo} missing tokenizer inputs: {missing_inputs}")
        payloads = [
            bounded_fetch(f"{base}/{name}", max_fetch, sizes[name])
            for name in generated.input_paths
        ]
        bundled_payload = build_qwen_tokenizer_json(*payloads)
        artifacts.append({
            "relativePath": generated.relative_path,
            "downloadURL": f"bundle://{generated.bundle_resource}",
            "sha256Hex": hashlib.sha256(bundled_payload).hexdigest(),
            "byteCount": len(bundled_payload),
        })
        stats["files"] += 1
        stats["bytes"] += len(bundled_payload)
    artifacts.sort(key=lambda a: str(a["relativePath"]))
    manifest = {
        "modelID": spec.model_id,
        "version": "; ".join(version_parts),
        "artifacts": artifacts,
    }
    return manifest, bundled_payload, stats


def check_frozen(fresh: list[dict[str, object]], catalog_path: Path) -> None:
    existing = json.loads(catalog_path.read_text())
    if existing != fresh:
        for old, new in zip(existing, fresh):
            if old != new:
                old_rev = {a["downloadURL"] for a in old["artifacts"]}
                new_rev = {a["downloadURL"] for a in new["artifacts"]}
                raise RuntimeError(
                    f"Frozen rebuild of {new.get('modelID')} diverges from catalog: "
                    f"{sorted(old_rev - new_rev)[:3]} vs {sorted(new_rev - old_rev)[:3]}")
        raise RuntimeError("Frozen rebuild diverges from existing catalog")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate the verified development model catalog plus bundled tokenizer assets.")
    parser.add_argument("--out", type=Path, default=Path("Resources/Models/catalog.json"))
    parser.add_argument("--tokenizer-out", type=Path,
                        default=Path("Resources/Models/qwen3-tokenizer.json"))
    parser.add_argument("--max-fetch-bytes", type=int, default=DEFAULT_MAX_FETCH_BYTES)
    parser.add_argument("--frozen", action="store_true",
                        help="Reuse revisions pinned in --out instead of resolving HEAD; "
                             "fails if rebuilt content would differ")
    args = parser.parse_args()
    pins = pinned_revisions(args.out) if args.frozen else None
    manifests: list[dict[str, object]] = []
    bundled: dict[str, bytes] = {}
    for spec in MODEL_SPECS:
        manifest, payload, stats = build_manifest(spec, pins, args.max_fetch_bytes)
        manifests.append(manifest)
        print(f"{spec.model_id}: {stats['files']} artifacts, "
              f"{stats['bytes']} bytes pinned, {stats['fetched']} remote files hashed",
              file=sys.stderr)
        if payload is not None:
            bundled[args.tokenizer_out] = payload
    if args.frozen:
        check_frozen(manifests, args.out)
        for target, payload in bundled.items():
            if target.is_file() and target.read_bytes() != payload:
                raise RuntimeError(f"Frozen rebuild would change bundled file {target}")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(manifests, indent=2, ensure_ascii=False) + "\n")
    print(f"wrote {args.out}", file=sys.stderr)
    for target, payload in bundled.items():
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(payload)
        print(f"wrote {target} ({len(payload)} bytes, "
              f"sha256 {hashlib.sha256(payload).hexdigest()})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, urllib.error.URLError, OSError) as error:
        sys.exit(f"catalog build failed: {error}")
