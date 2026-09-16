#!/usr/bin/env python3
import argparse
import json
import math
import sys
import unicodedata
from dataclasses import dataclass
from pathlib import Path

EVALUATION_SCHEMA = "goat-voice.release-evaluation/1"
REPORT_SCHEMA = "goat-voice.release-evaluation-report/1"
NORMALIZATION_ID = "nfc.casefold.drop-pc.collapse-ws/1"
TOKEN_MATCH_ID = "nfc-exact-substring/1"
PERCENTILE_ID = "linear-interpolation/1"

EXIT_PASS = 0
EXIT_FAIL = 1
EXIT_INCOMPLETE = 2
EXIT_INPUT_ERROR = 3

PASS = "pass"
FAIL = "fail"
INCOMPLETE = "incomplete"
VERDICT_RANK = {FAIL: 0, INCOMPLETE: 1, PASS: 2}

REQUIRED_CONFIG_FIELDS = (
    "mac_model",
    "chip",
    "ram",
    "macos",
    "model",
    "model_format_quantization",
    "backend_build",
    "warm_cold",
    "test_dataset_version",
)
WARM_STATE = "warm"

LANGUAGES = ("ko", "en", "mixed")
REVIEW_KINDS = ("ko", "en", "mixed", "developer")
REVIEW_MIXED_DEV_KINDS = frozenset({"mixed", "developer"})
CLASSIFICATIONS = ("preserved", "degraded", "critical")

TARGET_MODES = (
    "textedit",
    "terminal_app_shell",
    "iterm2_shell",
    "vscode_editor",
    "vscode_terminal",
    "cursor_editor",
    "safari_textarea",
    "chrome_textarea",
)
OUTCOMES = ("inserted", "recovered", "failed")
SAFETY_FAILURES = (
    "wrong_target",
    "duplicate_delivery",
    "unintended_submit",
    "clipboard_precedence",
)
RECOVERY_REASONS = (
    "post_release_mutation",
    "target_identity",
    "clipboard_snapshot",
    "other",
)

MIN_UTTERANCES = 600
MIN_SPEAKERS = 8
SUGGESTED_TECHNICAL_OCCURRENCES = 200
MIN_REVIEW_ITEMS = 50
MIN_REVIEW_MIXED_DEV = 25
MIN_LATENCY_SAMPLES = 300
LATENCY_P50_LIMIT_S = 0.5
LATENCY_P95_LIMIT_S = 1.0
SHORT_UTTERANCE_MIN_S = 3.0
SHORT_UTTERANCE_MAX_S = 5.0
MIN_FIRST_SYLLABLE_TRIALS = 200
MIN_FIRST_SYLLABLE_SPEAKERS = 2
MIN_FIRST_SYLLABLE_VOICE_LEVELS = 2
MIN_FIRST_SYLLABLE_OFFSETS = 2
TRIGGER_CAPTURE_LIMIT_MS = 50.0
TRIGGER_STRIP_LIMIT_MS = 100.0
MIN_ELIGIBLE_ATTEMPTS = 2000
MIN_ELIGIBLE_PER_MODE = 250
MAX_FAILURES_PER_1000_ELIGIBLE = 1

VALIDATED_SUPPORT = "validated"
NOT_VALIDATED_SUPPORT = "not_validated"
UNKNOWN_SUPPORT = "unknown"

SCOPE_INFORMS = ("VAL-001", "VAL-004", "VAL-022")
SCOPE_NOT_EVALUATED = (
    "VAL-002", "VAL-003", "VAL-005", "VAL-006", "VAL-007", "VAL-008",
    "VAL-009", "VAL-010", "VAL-011", "VAL-012", "VAL-013", "VAL-014",
    "VAL-015", "VAL-016", "VAL-017", "VAL-018", "VAL-019", "VAL-020",
    "VAL-021",
)


class EvidenceError(Exception):
    pass


@dataclass(frozen=True)
class Utterance:
    id: str
    speaker_id: str
    language: str
    reference: str
    hypothesis: str
    duration_s: float | None
    technical_tokens: tuple[str, ...]


@dataclass(frozen=True)
class ReviewItem:
    id: str
    utterance_id: str
    kind: str
    classification: str


@dataclass(frozen=True)
class LatencySample:
    id: str
    seconds: float
    utterance_duration_s: float
    trigger_to_capture_ms: float | None
    trigger_to_strip_ms: float | None


@dataclass(frozen=True)
class FirstSyllableTrial:
    id: str
    speaker_id: str
    voice_level: str
    offset_ms: float
    lost: bool


@dataclass(frozen=True)
class TargetValidation:
    id: str
    target_mode: str
    validated: bool


@dataclass(frozen=True)
class InsertionAttempt:
    id: str
    target_mode: str
    eligible: bool
    outcome: str
    success: bool | None
    safety_failure: str | None
    recovery_reason: str | None


@dataclass
class Evidence:
    reference_configuration: dict | None = None
    utterances: list[Utterance] | None = None
    review_items: list[ReviewItem] | None = None
    latency_samples: list[LatencySample] | None = None
    first_syllable_trials: list[FirstSyllableTrial] | None = None
    insertion_attempts: list[InsertionAttempt] | None = None
    target_validations: list[TargetValidation] | None = None


@dataclass
class GateResult:
    verdict: str
    summary: str
    details: dict

    def as_dict(self) -> dict:
        return {
            "verdict": self.verdict,
            "summary": self.summary,
            "details": self.details,
        }


def _reject_constant(value: str):
    raise EvidenceError(f"non-standard JSON constant '{value}'")


def load_json_file(path: Path):
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError as error:
        raise EvidenceError(f"{path}: cannot read file: {error.strerror or error}")
    try:
        return json.loads(text, parse_constant=_reject_constant)
    except json.JSONDecodeError as error:
        raise EvidenceError(
            f"{path}: invalid JSON at line {error.lineno} column {error.colno}"
        )


def load_jsonl_file(path: Path) -> list:
    records = []
    try:
        with Path(path).open(encoding="utf-8") as handle:
            for lineno, line in enumerate(handle, 1):
                if not line.strip():
                    continue
                try:
                    records.append(json.loads(line, parse_constant=_reject_constant))
                except json.JSONDecodeError as error:
                    raise EvidenceError(
                        f"{path}:{lineno}: invalid JSON record: {error.msg}"
                    )
    except OSError as error:
        raise EvidenceError(f"{path}: cannot read file: {error.strerror or error}")
    return records


def load_record_section(path: Path, key: str) -> list:
    if str(path).endswith(".jsonl"):
        return load_jsonl_file(path)
    data = load_json_file(path)
    if isinstance(data, list):
        return data
    if isinstance(data, dict) and key in data:
        section = data[key]
        if isinstance(section, list):
            return section
    raise EvidenceError(
        f"{path}: expected a JSON array or an object containing '{key}'"
    )


def load_config_section(path: Path) -> dict:
    data = load_json_file(path)
    if isinstance(data, dict) and "reference_configuration" in data:
        data = data["reference_configuration"]
    if not isinstance(data, dict):
        raise EvidenceError(f"{path}: expected a JSON object")
    return data


def _ctx(label: str, index: int, record) -> str:
    if isinstance(record, dict):
        rid = record.get("id")
        if isinstance(rid, str) and rid:
            return f"{label} '{rid}'"
    return f"{label} #{index}"


def _required(record, key: str, ctx: str):
    if not isinstance(record, dict):
        raise EvidenceError(f"{ctx}: expected an object")
    if key not in record:
        raise EvidenceError(f"{ctx}: missing '{key}'")
    return record[key]


def _req_str(record, key: str, ctx: str) -> str:
    value = _required(record, key, ctx)
    if not isinstance(value, str):
        raise EvidenceError(f"{ctx}: '{key}' must be a string")
    return value


def _req_nonempty_str(record, key: str, ctx: str) -> str:
    value = _req_str(record, key, ctx)
    if not value:
        raise EvidenceError(f"{ctx}: '{key}' must not be empty")
    return value


def _req_bool(record, key: str, ctx: str) -> bool:
    value = _required(record, key, ctx)
    if not isinstance(value, bool):
        raise EvidenceError(f"{ctx}: '{key}' must be a boolean")
    return value


def _is_number(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _req_num(record, key: str, ctx: str) -> float:
    value = _required(record, key, ctx)
    if not _is_number(value) or not math.isfinite(value):
        raise EvidenceError(f"{ctx}: '{key}' must be a finite number")
    return float(value)


def _opt_num(record, key: str, ctx: str) -> float | None:
    if not isinstance(record, dict) or key not in record:
        return None
    value = record[key]
    if not _is_number(value) or not math.isfinite(value):
        raise EvidenceError(f"{ctx}: '{key}' must be a finite number")
    return float(value)


def _req_enum(record, key: str, ctx: str, allowed) -> str:
    value = _req_str(record, key, ctx)
    if value not in allowed:
        raise EvidenceError(f"{ctx}: '{key}' must be one of {list(allowed)}")
    return value


def _opt_enum(record, key: str, ctx: str, allowed) -> str | None:
    if not isinstance(record, dict) or key not in record:
        return None
    value = record[key]
    if value is not None and (not isinstance(value, str) or value not in allowed):
        raise EvidenceError(f"{ctx}: '{key}' must be one of {list(allowed)}")
    return value


def _check_unique(seen: set, uid: str, ctx: str):
    if uid in seen:
        raise EvidenceError(f"{ctx}: duplicate id")
    seen.add(uid)


def parse_utterances(raw, source: str) -> list[Utterance]:
    if not isinstance(raw, list):
        raise EvidenceError(f"{source}: expected a list of utterances")
    utterances = []
    seen = set()
    for index, record in enumerate(raw):
        ctx = _ctx("utterance", index, record)
        uid = _req_nonempty_str(record, "id", ctx)
        ctx = _ctx("utterance", index, record)
        _check_unique(seen, uid, ctx)
        language = _req_enum(record, "language", ctx, LANGUAGES)
        speaker_id = _req_nonempty_str(record, "speaker_id", ctx)
        reference = _req_str(record, "reference", ctx)
        hypothesis = _req_str(record, "hypothesis", ctx)
        duration = _opt_num(record, "duration_s", ctx)
        if duration is not None and duration <= 0:
            raise EvidenceError(f"{ctx}: 'duration_s' must be positive")
        raw_tokens = record.get("technical_tokens", [])
        if not isinstance(raw_tokens, list):
            raise EvidenceError(f"{ctx}: 'technical_tokens' must be a list")
        tokens = []
        for token_index, token_record in enumerate(raw_tokens):
            token_ctx = f"{ctx} technical_tokens[{token_index}]"
            if isinstance(token_record, str):
                token = token_record
            else:
                token = _req_nonempty_str(token_record, "token", token_ctx)
            if not token:
                raise EvidenceError(f"{token_ctx}: 'token' must not be empty")
            tokens.append(token)
        utterances.append(
            Utterance(
                id=uid,
                speaker_id=speaker_id,
                language=language,
                reference=reference,
                hypothesis=hypothesis,
                duration_s=duration,
                technical_tokens=tuple(tokens),
            )
        )
    return utterances


def parse_review_items(raw, source: str) -> list[ReviewItem]:
    if not isinstance(raw, list):
        raise EvidenceError(f"{source}: expected a list of review items")
    items = []
    seen = set()
    for index, record in enumerate(raw):
        ctx = _ctx("review item", index, record)
        uid = _req_nonempty_str(record, "id", ctx)
        ctx = _ctx("review item", index, record)
        _check_unique(seen, uid, ctx)
        items.append(
            ReviewItem(
                id=uid,
                utterance_id=_req_nonempty_str(record, "utterance_id", ctx),
                kind=_req_enum(record, "kind", ctx, REVIEW_KINDS),
                classification=_req_enum(
                    record, "classification", ctx, CLASSIFICATIONS
                ),
            )
        )
    return items


def parse_latency_samples(raw, source: str) -> list[LatencySample]:
    if not isinstance(raw, list):
        raise EvidenceError(f"{source}: expected a list of latency samples")
    samples = []
    seen = set()
    for index, record in enumerate(raw):
        ctx = _ctx("latency sample", index, record)
        uid = _req_nonempty_str(record, "id", ctx)
        ctx = _ctx("latency sample", index, record)
        _check_unique(seen, uid, ctx)
        seconds = _req_num(record, "seconds", ctx)
        if seconds < 0:
            raise EvidenceError(f"{ctx}: 'seconds' must be >= 0")
        duration = _req_num(record, "utterance_duration_s", ctx)
        if duration <= 0:
            raise EvidenceError(f"{ctx}: 'utterance_duration_s' must be positive")
        samples.append(
            LatencySample(
                id=uid,
                seconds=seconds,
                utterance_duration_s=duration,
                trigger_to_capture_ms=_opt_num(
                    record, "trigger_to_capture_ms", ctx
                ),
                trigger_to_strip_ms=_opt_num(
                    record, "trigger_to_strip_ms", ctx
                ),
            )
        )
    return samples


def parse_first_syllable_trials(raw, source: str) -> list[FirstSyllableTrial]:
    if not isinstance(raw, list):
        raise EvidenceError(f"{source}: expected a list of first-syllable trials")
    trials = []
    seen = set()
    for index, record in enumerate(raw):
        ctx = _ctx("first-syllable trial", index, record)
        uid = _req_nonempty_str(record, "id", ctx)
        ctx = _ctx("first-syllable trial", index, record)
        _check_unique(seen, uid, ctx)
        offset = _req_num(record, "offset_ms", ctx)
        if offset < 0:
            raise EvidenceError(f"{ctx}: 'offset_ms' must be >= 0")
        trials.append(
            FirstSyllableTrial(
                id=uid,
                speaker_id=_req_nonempty_str(record, "speaker_id", ctx),
                voice_level=_req_nonempty_str(record, "voice_level", ctx),
                offset_ms=offset,
                lost=_req_bool(record, "lost", ctx),
            )
        )
    return trials


def parse_target_validations(raw, source: str) -> list[TargetValidation]:
    if not isinstance(raw, list):
        raise EvidenceError(f"{source}: expected a list of target validations")
    validations = []
    seen = set()
    for index, record in enumerate(raw):
        ctx = _ctx("target validation", index, record)
        uid = _req_nonempty_str(record, "id", ctx)
        ctx = _ctx("target validation", index, record)
        _check_unique(seen, uid, ctx)
        validations.append(
            TargetValidation(
                id=uid,
                target_mode=_req_nonempty_str(record, "target_mode", ctx),
                validated=_req_bool(record, "validated", ctx),
            )
        )
    return validations


def parse_insertion_attempts(raw, source: str) -> list[InsertionAttempt]:
    if not isinstance(raw, list):
        raise EvidenceError(f"{source}: expected a list of insertion attempts")
    attempts = []
    seen = set()
    for index, record in enumerate(raw):
        ctx = _ctx("insertion attempt", index, record)
        uid = _req_nonempty_str(record, "id", ctx)
        ctx = _ctx("insertion attempt", index, record)
        _check_unique(seen, uid, ctx)
        target_mode = _req_nonempty_str(record, "target_mode", ctx)
        eligible = _req_bool(record, "eligible", ctx)
        outcome = _req_enum(record, "outcome", ctx, OUTCOMES)
        safety_failure = _opt_enum(record, "safety_failure", ctx, SAFETY_FAILURES)
        recovery_reason = _opt_enum(record, "recovery_reason", ctx, RECOVERY_REASONS)
        success = None
        if "success" in record:
            success = _req_bool(record, "success", ctx)
        if eligible and success is None:
            raise EvidenceError(f"{ctx}: eligible attempts require 'success'")
        if success and outcome != "inserted":
            raise EvidenceError(
                f"{ctx}: 'success' true requires outcome 'inserted'"
            )
        if outcome == "recovered" and recovery_reason is None:
            raise EvidenceError(
                f"{ctx}: outcome 'recovered' requires 'recovery_reason'"
            )
        if outcome != "recovered" and recovery_reason is not None:
            raise EvidenceError(
                f"{ctx}: 'recovery_reason' requires outcome 'recovered'"
            )
        if safety_failure is not None and outcome != "failed":
            raise EvidenceError(
                f"{ctx}: 'safety_failure' requires outcome 'failed'"
            )
        attempts.append(
            InsertionAttempt(
                id=uid,
                target_mode=target_mode,
                eligible=eligible,
                outcome=outcome,
                success=success,
                safety_failure=safety_failure,
                recovery_reason=recovery_reason,
            )
        )
    return attempts


def parse_reference_configuration(raw) -> dict:
    if not isinstance(raw, dict):
        raise EvidenceError("'reference_configuration' must be an object")
    config = dict(raw)
    for key, value in config.items():
        if not isinstance(key, str):
            raise EvidenceError("reference_configuration keys must be strings")
        if isinstance(value, (dict, list)):
            raise EvidenceError(
                f"reference_configuration '{key}' must be a scalar"
            )
    return config


def normalize_text(text: str) -> str:
    canonical = unicodedata.normalize("NFC", text).casefold()
    kept = [
        char
        for char in canonical
        if not unicodedata.category(char).startswith(("P", "C"))
    ]
    return " ".join("".join(kept).split())


def cer_units(text: str) -> list[str]:
    return [char for char in normalize_text(text) if not char.isspace()]


def wer_units(text: str) -> list[str]:
    normalized = normalize_text(text)
    return normalized.split() if normalized else []


def levenshtein(reference: list, hypothesis: list) -> int:
    if len(reference) < len(hypothesis):
        return levenshtein(hypothesis, reference)
    previous = list(range(len(hypothesis) + 1))
    for row, ref_item in enumerate(reference, 1):
        current = [row]
        for col, hyp_item in enumerate(hypothesis, 1):
            cost = 0 if ref_item == hyp_item else 1
            current.append(
                min(
                    previous[col] + 1,
                    current[col - 1] + 1,
                    previous[col - 1] + cost,
                )
            )
        previous = current
    return previous[-1]


def error_rate(reference_units: list, hypothesis_units: list) -> tuple[int, int]:
    return levenshtein(reference_units, hypothesis_units), len(reference_units)


def percentile(sorted_values: list[float], fraction: float) -> float:
    if not sorted_values:
        raise ValueError("percentile of empty sequence")
    if len(sorted_values) == 1:
        return sorted_values[0]
    position = fraction * (len(sorted_values) - 1)
    low = math.floor(position)
    high = math.ceil(position)
    if low == high:
        return sorted_values[low]
    weight = position - low
    return sorted_values[low] * (1 - weight) + sorted_values[high] * weight


def token_preserved(token: str, hypothesis: str) -> bool:
    return unicodedata.normalize("NFC", token) in unicodedata.normalize(
        "NFC", hypothesis
    )


def _rate(numerator: int, denominator: int) -> float | None:
    if denominator == 0:
        return None
    return round(numerator / denominator, 6)


def corpus_metrics(utterances: list[Utterance]) -> dict:
    def language_error_rate(language: str, units) -> dict:
        group = [u for u in utterances if u.language == language]
        distance = 0
        total = 0
        for utterance in group:
            d, n = error_rate(units(utterance.reference), units(utterance.hypothesis))
            distance += d
            total += n
        return {
            "value": _rate(distance, total),
            "utterances": len(group),
            "reference_units": total,
        }

    tagged = 0
    preserved = 0
    missed_ids = []
    for utterance in utterances:
        missed_here = False
        for token in utterance.technical_tokens:
            tagged += 1
            if token_preserved(token, utterance.hypothesis):
                preserved += 1
            else:
                missed_here = True
        if missed_here:
            missed_ids.append(utterance.id)
    return {
        "korean_cer": language_error_rate("ko", cer_units),
        "english_wer": language_error_rate("en", wer_units),
        "mixed_cer": language_error_rate("mixed", cer_units),
        "technical_token_preservation": {
            "tagged_occurrences": tagged,
            "preserved": preserved,
            "rate": _rate(preserved, tagged),
            "missed_utterance_ids": missed_ids,
        },
    }


def dataset_summary(utterances: list[Utterance]) -> dict:
    durations = [u.duration_s for u in utterances if u.duration_s is not None]
    summary = {
        "utterances": len(utterances),
        "speakers": len({u.speaker_id for u in utterances}),
        "per_language": {
            language: sum(1 for u in utterances if u.language == language)
            for language in LANGUAGES
        },
        "tagged_technical_occurrences": sum(
            len(u.technical_tokens) for u in utterances
        ),
    }
    if durations:
        summary["durations"] = {
            "annotated": len(durations),
            "min_s": min(durations),
            "max_s": max(durations),
            "short_3_5s": sum(1 for d in durations if 3.0 <= d <= 5.0),
            "medium_6_15s": sum(1 for d in durations if 6.0 <= d <= 15.0),
        }
    return summary


def gate_reference_configuration(evidence: Evidence) -> GateResult:
    config = evidence.reference_configuration
    if config is None:
        return GateResult(
            INCOMPLETE, "reference configuration absent", {"missing_fields": list(REQUIRED_CONFIG_FIELDS)}
        )
    missing = [
        key
        for key in REQUIRED_CONFIG_FIELDS
        if key not in config or config[key] is None or config[key] == ""
    ]
    if missing:
        return GateResult(
            INCOMPLETE,
            "reference configuration incomplete",
            {"missing_fields": missing},
        )
    return GateResult(PASS, "reference configuration frozen", {"fields": list(REQUIRED_CONFIG_FIELDS)})


def gate_asr_corpus(evidence: Evidence) -> GateResult:
    utterances = evidence.utterances
    if utterances is None:
        return GateResult(INCOMPLETE, "asr corpus absent", {})
    details = dataset_summary(utterances)
    details["required_utterances"] = MIN_UTTERANCES
    details["required_speakers"] = MIN_SPEAKERS
    if len(utterances) < MIN_UTTERANCES:
        return GateResult(INCOMPLETE, "corpus below 600 utterances", details)
    if details["speakers"] < MIN_SPEAKERS:
        return GateResult(INCOMPLETE, "corpus below 8 speakers", details)
    missing_languages = [
        language
        for language in LANGUAGES
        if details["per_language"][language] == 0
    ]
    if missing_languages:
        details["missing_languages"] = missing_languages
        return GateResult(
            INCOMPLETE, "corpus lacks required language coverage", details
        )
    if details["tagged_technical_occurrences"] == 0:
        return GateResult(
            INCOMPLETE, "corpus has no tagged technical tokens", details
        )
    return GateResult(PASS, "corpus size and coverage sufficient", details)


def gate_human_review(evidence: Evidence) -> GateResult:
    items = evidence.review_items
    if items is None:
        return GateResult(INCOMPLETE, "human review absent", {})
    kinds = {kind: 0 for kind in REVIEW_KINDS}
    counts = {name: 0 for name in CLASSIFICATIONS}
    critical_ids = []
    mixed_dev = 0
    for item in items:
        kinds[item.kind] += 1
        counts[item.classification] += 1
        if item.kind in REVIEW_MIXED_DEV_KINDS:
            mixed_dev += 1
        if item.classification == "critical":
            critical_ids.append(item.id)
    details = {
        "items": len(items),
        "required_items": MIN_REVIEW_ITEMS,
        "kinds": kinds,
        "classifications": counts,
        "mixed_or_developer": mixed_dev,
        "required_mixed_or_developer": MIN_REVIEW_MIXED_DEV,
        "critical_item_ids": critical_ids,
        "corpus_linked": evidence.utterances is not None,
    }
    if counts["critical"] > 0:
        return GateResult(FAIL, "critical instruction inversions observed", details)
    if len(items) < MIN_REVIEW_ITEMS:
        return GateResult(INCOMPLETE, "review set below 50 items", details)
    missing_kinds = [kind for kind in ("ko", "en", "mixed") if kinds[kind] == 0]
    if missing_kinds:
        details["missing_kinds"] = missing_kinds
        return GateResult(
            INCOMPLETE, "review set lacks required language examples", details
        )
    if mixed_dev < MIN_REVIEW_MIXED_DEV:
        return GateResult(
            INCOMPLETE, "review set below 25 mixed/developer items", details
        )
    return GateResult(PASS, "human review complete with zero critical", details)


def _latency_conditions(evidence: Evidence) -> tuple[str | None, dict]:
    samples = evidence.latency_samples
    details = {
        "samples": len(samples) if samples is not None else 0,
        "required_samples": MIN_LATENCY_SAMPLES,
    }
    if samples is None:
        return "latency evidence absent", details
    out_of_condition = [
        sample.id
        for sample in samples
        if not (SHORT_UTTERANCE_MIN_S <= sample.utterance_duration_s <= SHORT_UTTERANCE_MAX_S)
    ]
    if out_of_condition:
        details["out_of_condition_sample_ids"] = out_of_condition
        return "samples outside the 3-5 s utterance condition", details
    if len(samples) < MIN_LATENCY_SAMPLES:
        return "below 300 latency samples", details
    config = evidence.reference_configuration
    if config is None:
        return "latency requires a frozen reference configuration", details
    warm_cold = config.get("warm_cold")
    if warm_cold != WARM_STATE:
        details["warm_cold"] = warm_cold
        return "latency requires a warm reference run", details
    return None, details


def _trigger_latency_gate(evidence: Evidence, field: str, limit_ms: float,
                          label: str) -> GateResult:
    blocked, details = _latency_conditions(evidence)
    if blocked is not None:
        return GateResult(INCOMPLETE, blocked, details)
    samples = evidence.latency_samples
    missing = [
        sample.id for sample in samples if getattr(sample, field) is None
    ]
    if missing:
        details["missing_sample_ids"] = missing
        return GateResult(
            INCOMPLETE, f"{label} measurement missing on samples", details
        )
    values = [getattr(sample, field) for sample in samples]
    observed_max = max(values)
    details["limit_ms"] = limit_ms
    details["observed"] = {
        "n": len(values),
        "mean_ms": round(sum(values) / len(values), 3),
        "p95_ms": round(percentile(sorted(values), 0.95), 3),
        "max_ms": observed_max,
    }
    if observed_max < limit_ms:
        return GateResult(PASS, f"{label} within target", details)
    return GateResult(FAIL, f"{label} exceeds target", details)


def gate_trigger_capture(evidence: Evidence) -> GateResult:
    return _trigger_latency_gate(
        evidence, "trigger_to_capture_ms", TRIGGER_CAPTURE_LIMIT_MS,
        "trigger-to-capture",
    )


def gate_trigger_strip(evidence: Evidence) -> GateResult:
    return _trigger_latency_gate(
        evidence, "trigger_to_strip_ms", TRIGGER_STRIP_LIMIT_MS,
        "trigger-to-strip",
    )


def gate_latency(evidence: Evidence) -> GateResult:
    blocked, details = _latency_conditions(evidence)
    if blocked is not None:
        return GateResult(INCOMPLETE, blocked, details)
    samples = evidence.latency_samples
    details["limits_s"] = {
        "p50": LATENCY_P50_LIMIT_S,
        "p95": LATENCY_P95_LIMIT_S,
    }
    values = sorted(sample.seconds for sample in samples)
    p50 = percentile(values, 0.5)
    p95 = percentile(values, 0.95)
    details["p50_s"] = round(p50, 6)
    details["p95_s"] = round(p95, 6)
    if p50 < LATENCY_P50_LIMIT_S and p95 < LATENCY_P95_LIMIT_S:
        return GateResult(PASS, "warm short-path latency within targets", details)
    return GateResult(FAIL, "warm short-path latency exceeds targets", details)


def gate_first_syllable(evidence: Evidence) -> GateResult:
    trials = evidence.first_syllable_trials
    if trials is None:
        return GateResult(INCOMPLETE, "first-syllable evidence absent", {})
    loss_ids = [trial.id for trial in trials if trial.lost]
    speakers = len({trial.speaker_id for trial in trials})
    voice_levels = len({trial.voice_level for trial in trials})
    offsets = len({trial.offset_ms for trial in trials})
    details = {
        "trials": len(trials),
        "required_trials": MIN_FIRST_SYLLABLE_TRIALS,
        "speakers": speakers,
        "voice_levels": voice_levels,
        "offsets_ms": offsets,
        "losses": len(loss_ids),
        "loss_ids": loss_ids,
    }
    if loss_ids:
        return GateResult(FAIL, "first-syllable losses observed", details)
    if len(trials) < MIN_FIRST_SYLLABLE_TRIALS:
        return GateResult(INCOMPLETE, "below 200 immediate-speech trials", details)
    if speakers < MIN_FIRST_SYLLABLE_SPEAKERS:
        return GateResult(INCOMPLETE, "trials must span multiple speakers", details)
    if voice_levels < MIN_FIRST_SYLLABLE_VOICE_LEVELS:
        return GateResult(
            INCOMPLETE, "trials must span multiple voice levels", details
        )
    if offsets < MIN_FIRST_SYLLABLE_OFFSETS:
        return GateResult(
            INCOMPLETE, "trials must span multiple immediate offsets", details
        )
    return GateResult(PASS, "zero first-syllable losses observed", details)


def gate_insertion(evidence: Evidence) -> GateResult:
    attempts = evidence.insertion_attempts
    if attempts is None:
        return GateResult(INCOMPLETE, "insertion evidence absent", {})
    eligible = [a for a in attempts if a.eligible]
    successes = sum(1 for a in eligible if a.success)
    failures = len(eligible) - successes
    safety = [a for a in attempts if a.safety_failure is not None]
    per_mode = {
        mode: sum(1 for a in eligible if a.target_mode == mode)
        for mode in TARGET_MODES
    }
    details = {
        "attempts": len(attempts),
        "eligible": len(eligible),
        "required_eligible": MIN_ELIGIBLE_ATTEMPTS,
        "successes": successes,
        "success_rate": _rate(successes, len(eligible)),
        "required_success_rate": 0.999,
        "safety_failures": len(safety),
        "safety_failure_ids": [a.id for a in safety],
        "safety_failure_kinds": {
            kind: sum(1 for a in safety if a.safety_failure == kind)
            for kind in SAFETY_FAILURES
            if any(a.safety_failure == kind for a in safety)
        },
        "per_mode_eligible": per_mode,
        "required_per_mode": MIN_ELIGIBLE_PER_MODE,
    }
    if safety:
        return GateResult(FAIL, "safety failures observed", details)
    if len(eligible) < MIN_ELIGIBLE_ATTEMPTS:
        return GateResult(INCOMPLETE, "below 2000 eligible attempts", details)
    short_modes = [
        mode for mode, count in per_mode.items() if count < MIN_ELIGIBLE_PER_MODE
    ]
    if short_modes:
        details["modes_below_minimum"] = short_modes
        return GateResult(
            INCOMPLETE, "target modes below 250 eligible attempts", details
        )
    if failures * 1000 > len(eligible):
        return GateResult(FAIL, "observed success below 99.9%", details)
    return GateResult(PASS, "eligible insertion reliability met", details)


def validated_support_by_mode(
    validations: list[TargetValidation] | None,
) -> dict:
    support = {}
    for validation in validations or []:
        previous = support.get(validation.target_mode)
        support[validation.target_mode] = (
            validation.validated if previous is None
            else previous and validation.validated
        )
    return support


def coverage_by_mode(
    attempts: list[InsertionAttempt],
    validations: list[TargetValidation] | None = None,
) -> dict:
    support = validated_support_by_mode(validations)
    per_mode = {}
    modes = sorted({a.target_mode for a in attempts})
    for mode in modes:
        group = [a for a in attempts if a.target_mode == mode]
        total = len(group)
        inserted = sum(1 for a in group if a.outcome == "inserted")
        recovered = sum(1 for a in group if a.outcome == "recovered")
        failed = sum(1 for a in group if a.outcome == "failed")
        reasons = {reason: 0 for reason in RECOVERY_REASONS}
        for attempt in group:
            if attempt.recovery_reason is not None:
                reasons[attempt.recovery_reason] += 1
        validated = support.get(mode)
        per_mode[mode] = {
            "attempts": total,
            "automatic_insertion_rate": _rate(inserted, total),
            "clipboard_recovery_rate": _rate(recovered, total),
            "final_failure_rate": _rate(failed, total),
            "recovery_reasons": reasons,
            "observed_automatic_insertion": inserted > 0,
            "validated_support": (
                VALIDATED_SUPPORT if validated is True
                else NOT_VALIDATED_SUPPORT if validated is False
                else UNKNOWN_SUPPORT
            ),
        }
    return per_mode


def gate_coverage(evidence: Evidence) -> GateResult:
    attempts = evidence.insertion_attempts
    if attempts is None:
        return GateResult(INCOMPLETE, "normal-use coverage absent", {})
    per_mode = coverage_by_mode(attempts)
    missing = [mode for mode in TARGET_MODES if mode not in per_mode]
    details = {
        "required_modes": list(TARGET_MODES),
        "modes_reported": sorted(per_mode),
        "missing_modes": missing,
    }
    if missing:
        return GateResult(
            INCOMPLETE, "normal-use coverage missing target modes", details
        )
    return GateResult(PASS, "whole normal-use coverage reported", details)


def evaluate(evidence: Evidence) -> dict:
    gates = {
        "reference_configuration": gate_reference_configuration(evidence),
        "asr_corpus": gate_asr_corpus(evidence),
        "human_review": gate_human_review(evidence),
        "latency": gate_latency(evidence),
        "trigger_capture": gate_trigger_capture(evidence),
        "trigger_strip": gate_trigger_strip(evidence),
        "first_syllable": gate_first_syllable(evidence),
        "insertion": gate_insertion(evidence),
        "normal_use_coverage": gate_coverage(evidence),
    }
    overall = PASS
    for gate in gates.values():
        if VERDICT_RANK[gate.verdict] < VERDICT_RANK[overall]:
            overall = gate.verdict
    notes = []
    if evidence.utterances is not None:
        tagged = sum(len(u.technical_tokens) for u in evidence.utterances)
        if 0 < tagged < SUGGESTED_TECHNICAL_OCCURRENCES:
            notes.append(
                f"tagged technical occurrences {tagged} below suggested {SUGGESTED_TECHNICAL_OCCURRENCES}"
            )
    metrics = None
    if evidence.utterances:
        metrics = corpus_metrics(evidence.utterances)
    coverage = None
    if evidence.insertion_attempts is not None:
        coverage = {
            "per_target_mode": coverage_by_mode(
                evidence.insertion_attempts, evidence.target_validations
            )
        }
    return {
        "schema": REPORT_SCHEMA,
        "verdict": overall,
        "scope": {
            "verdict_covers": "supplied automated evaluation gates only",
            "informs": list(SCOPE_INFORMS),
            "not_evaluated": list(SCOPE_NOT_EVALUATED),
            "disclaimer": (
                "a pass verdict is not complete v1 release readiness; "
                "manual validation matrix items, platform QA, signing and "
                "distribution remain independent"
            ),
        },
        "normalization": {
            "text": NORMALIZATION_ID,
            "technical_token_match": TOKEN_MATCH_ID,
            "percentile": PERCENTILE_ID,
        },
        "reference_configuration": evidence.reference_configuration,
        "gates": {name: gate.as_dict() for name, gate in gates.items()},
        "metrics": metrics,
        "coverage": coverage,
        "notes": notes,
    }


def render_text(report: dict) -> str:
    lines = [
        f"verdict: {report['verdict']}",
        "scope: supplied automated gates only; not complete v1 release readiness",
    ]
    config = report.get("reference_configuration")
    if config:
        model = config.get("model", "?")
        quant = config.get("model_format_quantization", "?")
        lines.append(f"candidate: {model} ({quant})")
    for name, gate in report["gates"].items():
        lines.append(f"gate {name}: {gate['verdict']} - {gate['summary']}")
    metrics = report.get("metrics")
    if metrics is None:
        lines.append("metrics: unavailable (no asr corpus evidence)")
    else:
        for key in ("korean_cer", "english_wer", "mixed_cer"):
            metric = metrics[key]
            value = metric["value"]
            shown = "n/a" if value is None else f"{value:.6f}"
            lines.append(
                f"metric {key}: {shown} "
                f"({metric['utterances']} utterances, {metric['reference_units']} reference units)"
            )
        token_metric = metrics["technical_token_preservation"]
        rate = token_metric["rate"]
        shown = "n/a" if rate is None else f"{rate:.6f}"
        lines.append(
            f"metric technical_token_preservation: {shown} "
            f"({token_metric['preserved']}/{token_metric['tagged_occurrences']} tagged occurrences)"
        )
    coverage = report.get("coverage")
    if coverage:
        for mode, stats in coverage["per_target_mode"].items():
            lines.append(
                f"coverage {mode}: attempts={stats['attempts']} "
                f"auto={stats['automatic_insertion_rate']} "
                f"recovery={stats['clipboard_recovery_rate']} "
                f"failed={stats['final_failure_rate']} "
                f"observed_automatic_insertion={stats['observed_automatic_insertion']} "
                f"validated_support={stats['validated_support']}"
            )
    for note in report.get("notes", []):
        lines.append(f"note: {note}")
    return "\n".join(lines)


class EvalArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        self.exit(EXIT_INPUT_ERROR, f"{self.prog}: error: {message}\n")


def build_parser() -> argparse.ArgumentParser:
    parser = EvalArgumentParser(
        description=(
            "Evaluate local release evidence for the voice-typing release gates. "
            "Inputs are local JSON/JSONL files only; the report contains ids and "
            "aggregate metrics, never transcript content."
        )
    )
    parser.add_argument(
        "--input",
        type=Path,
        help="single JSON evaluation document (schema goat-voice.release-evaluation/1)",
    )
    parser.add_argument("--config", type=Path, help="reference configuration JSON object")
    parser.add_argument("--corpus", type=Path, help="ASR corpus (.json array/object or .jsonl)")
    parser.add_argument("--human-review", type=Path, help="human review items (.json or .jsonl)")
    parser.add_argument("--latency", type=Path, help="latency samples (.json or .jsonl)")
    parser.add_argument("--first-syllable", type=Path, help="first-syllable trials (.json or .jsonl)")
    parser.add_argument("--insertion", type=Path, help="insertion attempts (.json or .jsonl)")
    parser.add_argument(
        "--target-validation",
        type=Path,
        help="independent per-target validation records (.json or .jsonl)",
    )
    parser.add_argument(
        "--format",
        choices=("text", "json"),
        default="text",
        help="stdout report format (default: text)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="optional path for the JSON report (aggregates and ids only)",
    )
    return parser


def _document_section(document: dict, key: str):
    if key not in document:
        return None
    section = document[key]
    if key != "reference_configuration" and not isinstance(section, list):
        raise EvidenceError(f"--input: '{key}' must be a list")
    return section


def collect_evidence(args) -> Evidence:
    document = {}
    if args.input is not None:
        data = load_json_file(args.input)
        if not isinstance(data, dict):
            raise EvidenceError(f"{args.input}: expected a JSON object")
        schema = data.get("schema")
        if schema != EVALUATION_SCHEMA:
            raise EvidenceError(
                f"{args.input}: 'schema' must be '{EVALUATION_SCHEMA}'"
            )
        document = data
    config_raw = (
        load_config_section(args.config)
        if args.config is not None
        else _document_section(document, "reference_configuration")
    )
    corpus_raw = (
        load_record_section(args.corpus, "utterances")
        if args.corpus is not None
        else _document_section(document, "utterances")
    )
    review_raw = (
        load_record_section(args.human_review, "human_review")
        if args.human_review is not None
        else _document_section(document, "human_review")
    )
    latency_raw = (
        load_record_section(args.latency, "latency_samples")
        if args.latency is not None
        else _document_section(document, "latency_samples")
    )
    trials_raw = (
        load_record_section(args.first_syllable, "first_syllable_trials")
        if args.first_syllable is not None
        else _document_section(document, "first_syllable_trials")
    )
    attempts_raw = (
        load_record_section(args.insertion, "insertion_attempts")
        if args.insertion is not None
        else _document_section(document, "insertion_attempts")
    )
    validations_raw = (
        load_record_section(args.target_validation, "target_validation")
        if args.target_validation is not None
        else _document_section(document, "target_validation")
    )
    evidence = Evidence()
    if config_raw is not None:
        evidence.reference_configuration = parse_reference_configuration(config_raw)
    if corpus_raw is not None:
        evidence.utterances = parse_utterances(corpus_raw, "corpus")
    if review_raw is not None:
        evidence.review_items = parse_review_items(review_raw, "human_review")
    if latency_raw is not None:
        evidence.latency_samples = parse_latency_samples(latency_raw, "latency")
    if trials_raw is not None:
        evidence.first_syllable_trials = parse_first_syllable_trials(
            trials_raw, "first_syllable"
        )
    if attempts_raw is not None:
        evidence.insertion_attempts = parse_insertion_attempts(
            attempts_raw, "insertion"
        )
    if validations_raw is not None:
        evidence.target_validations = parse_target_validations(
            validations_raw, "target_validation"
        )
    if evidence.review_items and evidence.utterances is not None:
        known = {u.id for u in evidence.utterances}
        for item in evidence.review_items:
            if item.utterance_id not in known:
                raise EvidenceError(
                    f"review item '{item.id}': utterance_id not present in corpus"
                )
    return evidence


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    try:
        evidence = collect_evidence(args)
    except EvidenceError as error:
        print(f"error: {error}", file=sys.stderr)
        return EXIT_INPUT_ERROR
    report = evaluate(evidence)
    if args.format == "json":
        print(json.dumps(report, indent=2, ensure_ascii=True))
    else:
        print(render_text(report))
    if args.output is not None:
        try:
            args.output.write_text(
                json.dumps(report, indent=2, ensure_ascii=True) + "\n",
                encoding="utf-8",
            )
        except OSError as error:
            print(f"error: cannot write report: {error}", file=sys.stderr)
            return EXIT_INPUT_ERROR
    if report["verdict"] == PASS:
        return EXIT_PASS
    if report["verdict"] == FAIL:
        return EXIT_FAIL
    return EXIT_INCOMPLETE


if __name__ == "__main__":
    sys.exit(main())
