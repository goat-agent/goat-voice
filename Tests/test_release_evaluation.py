import importlib.util
import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "tools" / "evaluate-release.py"

spec = importlib.util.spec_from_file_location("evaluate_release", TOOL)
er = importlib.util.module_from_spec(spec)
spec.loader.exec_module(er)

SECRET = "SECRET_SENTENCE_ZX9 never appears in reports"


def make_utterance(index, language="en", speaker=None, reference="hello world",
                   hypothesis=None, tokens=(), duration=4.0):
    return {
        "id": f"u-{index:04d}",
        "speaker_id": speaker or f"spk-{index % 8:02d}",
        "language": language,
        "reference": reference,
        "hypothesis": reference if hypothesis is None else hypothesis,
        "duration_s": duration,
        "technical_tokens": [{"token": token} for token in tokens],
    }


def make_corpus(ko=200, en=150, mixed=250, speakers=8, tech_tokens=200):
    utterances = []
    index = 0
    for language, count in (("ko", ko), ("en", en), ("mixed", mixed)):
        for _ in range(count):
            speaker = f"spk-{(index % speakers):02d}"
            tokens = ()
            if tech_tokens > 0:
                tokens = ("PostgreSQL",)
                tech_tokens -= 1
            utterances.append(
                make_utterance(index, language, speaker, "sample reference", tokens=tokens)
            )
            index += 1
    return utterances


def make_review(items=50, mixed_dev=25, critical=0, utterance_ids=None):
    ids = utterance_ids or [f"u-{i:04d}" for i in range(items)]
    kinds = []
    remaining_dev = mixed_dev
    for i in range(items):
        if remaining_dev > 0:
            kinds.append("mixed" if i % 2 == 0 else "developer")
            remaining_dev -= 1
        else:
            kinds.append("ko" if i % 2 == 0 else "en")
    if "mixed" not in kinds:
        kinds[0] = "mixed"
    if "ko" not in kinds:
        kinds[1] = "ko"
    if "en" not in kinds:
        kinds[2] = "en"
    review = []
    for i in range(items):
        review.append(
            {
                "id": f"r-{i:03d}",
                "utterance_id": ids[i % len(ids)],
                "kind": kinds[i],
                "classification": "critical" if i < critical else "preserved",
            }
        )
    return review


def make_config(warm_cold="warm"):
    return {
        "mac_model": "MacBook Pro 14-inch",
        "chip": "Apple M4 Pro",
        "ram": "48 GB",
        "macos": "15.6",
        "model": "eval-model-a",
        "model_format_quantization": "mlx-4bit",
        "backend_build": "local-build-1",
        "warm_cold": warm_cold,
        "test_dataset_version": "eval-corpus-v1",
    }


def make_latency(n=300, low=0.40, high=None, high_count=0, duration=4.0):
    samples = []
    for i in range(n):
        value = high if high is not None and i >= n - high_count else low
        samples.append(
            {
                "id": f"l-{i:03d}",
                "seconds": value,
                "utterance_duration_s": duration,
                "trigger_to_capture_ms": 30.0,
                "trigger_to_strip_ms": 80.0,
            }
        )
    return samples


def make_trials(n=200, speakers=4, losses=(), levels=("soft", "normal", "loud"),
                offsets=(0.0, 40.0, 80.0)):
    return [
        {
            "id": f"f-{i:03d}",
            "speaker_id": f"spk-{i % speakers:02d}",
            "voice_level": levels[i % len(levels)],
            "offset_ms": offsets[i % len(offsets)],
            "lost": i in losses,
        }
        for i in range(n)
    ]


def make_target_validations(modes=er.TARGET_MODES, validated=True):
    return [
        {"id": f"tv-{i:02d}", "target_mode": mode, "validated": validated}
        for i, mode in enumerate(modes)
    ]


def make_attempts(per_mode=250, modes=er.TARGET_MODES, fail_ids=(),
                  safety=None, recovered_ids=(), ineligible_per_mode=0):
    attempts = []
    index = 0
    for mode in modes:
        for _ in range(per_mode):
            aid = f"i-{index:05d}"
            if aid in recovered_ids:
                outcome, success, reason = "recovered", False, "post_release_mutation"
            elif aid in fail_ids:
                outcome, success, reason = "failed", False, None
            else:
                outcome, success, reason = "inserted", True, None
            attempt = {
                "id": aid,
                "target_mode": mode,
                "eligible": True,
                "outcome": outcome,
                "success": success,
            }
            if reason:
                attempt["recovery_reason"] = reason
            if safety and aid in safety:
                attempt["safety_failure"] = safety[aid]
                attempt["outcome"] = "failed"
                attempt["success"] = False
            attempts.append(attempt)
            index += 1
        for _ in range(ineligible_per_mode):
            aid = f"i-{index:05d}"
            attempts.append(
                {
                    "id": aid,
                    "target_mode": mode,
                    "eligible": False,
                    "outcome": "recovered",
                    "recovery_reason": "target_identity",
                }
            )
            index += 1
    return attempts


def full_evidence():
    corpus = make_corpus()
    return er.Evidence(
        reference_configuration=make_config(),
        utterances=er.parse_utterances(corpus, "test"),
        review_items=er.parse_review_items(
            make_review(utterance_ids=[u["id"] for u in corpus]), "test"
        ),
        latency_samples=er.parse_latency_samples(make_latency(), "test"),
        first_syllable_trials=er.parse_first_syllable_trials(make_trials(), "test"),
        insertion_attempts=er.parse_insertion_attempts(make_attempts(), "test"),
    )


class NormalizationTests(unittest.TestCase):
    def test_casefold_punctuation_whitespace(self):
        self.assertEqual(er.normalize_text("  Hello,  World!\t"), "hello world")

    def test_nfc_unifies_codepoints(self):
        combining = "Café"
        precomposed = "Café"
        self.assertEqual(er.normalize_text(combining), er.normalize_text(precomposed))

    def test_deterministic(self):
        self.assertEqual(er.normalize_text("A  B?!C"), er.normalize_text("A  B?!C"))

    def test_cer_units_drop_spaces(self):
        self.assertEqual(er.cer_units("a b c"), ["a", "b", "c"])

    def test_wer_units_split_words(self):
        self.assertEqual(er.wer_units("the quick fox"), ["the", "quick", "fox"])


class MetricTests(unittest.TestCase):
    def test_levenshtein(self):
        self.assertEqual(er.levenshtein(list("kitten"), list("sitting")), 3)
        self.assertEqual(er.levenshtein([], []), 0)
        self.assertEqual(er.levenshtein(["a"], []), 1)

    def test_korean_cer_substitution(self):
        metrics = er.corpus_metrics(
            er.parse_utterances(
                [make_utterance(0, "ko", reference="안녕하세요", hypothesis="안녕하세여")],
                "test",
            )
        )
        self.assertAlmostEqual(metrics["korean_cer"]["value"], 0.2)

    def test_korean_cer_ignores_spaces(self):
        metrics = er.corpus_metrics(
            er.parse_utterances(
                [make_utterance(0, "ko", reference="안녕 하세요", hypothesis="안녕하세요")],
                "test",
            )
        )
        self.assertEqual(metrics["korean_cer"]["value"], 0.0)

    def test_english_wer_deletion(self):
        metrics = er.corpus_metrics(
            er.parse_utterances(
                [
                    make_utterance(
                        0, "en",
                        reference="the quick brown fox",
                        hypothesis="the quick fox",
                    )
                ],
                "test",
            )
        )
        self.assertAlmostEqual(metrics["english_wer"]["value"], 0.25)

    def test_wer_empty_reference(self):
        both_empty = er.error_rate(er.wer_units(""), er.wer_units(""))
        self.assertEqual(both_empty, (0, 0))
        all_empty = er.corpus_metrics(
            er.parse_utterances(
                [make_utterance(0, "en", reference="", hypothesis="spoken words")],
                "test",
            )
        )
        self.assertIsNone(all_empty["english_wer"]["value"])
        mixed = er.corpus_metrics(
            er.parse_utterances(
                [
                    make_utterance(0, "en", reference="", hypothesis="spoken words"),
                    make_utterance(1, "en", reference="a b c d", hypothesis="a b c d"),
                ],
                "test",
            )
        )
        self.assertAlmostEqual(mixed["english_wer"]["value"], 0.5)

    def test_corpus_metrics_micro_average(self):
        utterances = er.parse_utterances(
            [
                make_utterance(0, "ko", reference="가나다라", hypothesis="가나다라"),
                make_utterance(1, "ko", reference="가나다라", hypothesis="가나다바"),
            ],
            "test",
        )
        metrics = er.corpus_metrics(utterances)
        self.assertAlmostEqual(metrics["korean_cer"]["value"], 0.125)

    def test_technical_token_exact_case_sensitive(self):
        utterances = er.parse_utterances(
            [
                make_utterance(
                    0, "mixed",
                    reference="call useEffect now",
                    hypothesis="call useEffect now",
                    tokens=("useEffect",),
                ),
                make_utterance(
                    1, "mixed",
                    reference="call useEffect now",
                    hypothesis="call useeffect now",
                    tokens=("useEffect",),
                ),
                make_utterance(
                    2, "mixed",
                    reference="i use PostgreSQL daily",
                    hypothesis="i use PostgreSQL daily",
                    tokens=("PostgreSQL",),
                ),
            ],
            "test",
        )
        metrics = er.corpus_metrics(utterances)
        preservation = metrics["technical_token_preservation"]
        self.assertEqual(preservation["tagged_occurrences"], 3)
        self.assertEqual(preservation["preserved"], 2)
        self.assertAlmostEqual(preservation["rate"], round(2 / 3, 6))
        self.assertEqual(preservation["missed_utterance_ids"], ["u-0001"])

    def test_percentile_linear_interpolation(self):
        values = sorted(range(1, 101))
        values = [float(v) for v in values]
        self.assertAlmostEqual(er.percentile(values, 0.5), 50.5)
        self.assertAlmostEqual(er.percentile(values, 0.95), 95.05)
        self.assertEqual(er.percentile([0.4], 0.95), 0.4)
        self.assertAlmostEqual(er.percentile([0.2, 0.8], 0.5), 0.5)


class GateTests(unittest.TestCase):
    def test_empty_evidence_all_incomplete(self):
        report = er.evaluate(er.Evidence())
        self.assertEqual(report["verdict"], "incomplete")
        for gate in report["gates"].values():
            self.assertEqual(gate["verdict"], "incomplete")
        self.assertIsNone(report["metrics"])

    def test_reference_configuration_fields(self):
        evidence = er.Evidence(reference_configuration=make_config())
        gate = er.gate_reference_configuration(evidence)
        self.assertEqual(gate.verdict, "pass")
        config = make_config()
        del config["backend_build"]
        evidence = er.Evidence(reference_configuration=config)
        gate = er.gate_reference_configuration(evidence)
        self.assertEqual(gate.verdict, "incomplete")
        self.assertEqual(gate.details["missing_fields"], ["backend_build"])

    def test_corpus_size_and_speakers(self):
        small = er.parse_utterances(make_corpus(ko=200, en=150, mixed=249), "test")
        gate = er.gate_asr_corpus(er.Evidence(utterances=small))
        self.assertEqual(gate.verdict, "incomplete")
        few_speakers = er.parse_utterances(
            make_corpus(speakers=7), "test"
        )
        gate = er.gate_asr_corpus(er.Evidence(utterances=few_speakers))
        self.assertEqual(gate.verdict, "incomplete")
        full = er.parse_utterances(make_corpus(), "test")
        gate = er.gate_asr_corpus(er.Evidence(utterances=full))
        self.assertEqual(gate.verdict, "pass")

    def test_corpus_requires_language_coverage_and_tokens(self):
        no_mixed = er.parse_utterances(
            make_corpus(ko=300, en=300, mixed=0), "test"
        )
        gate = er.gate_asr_corpus(er.Evidence(utterances=no_mixed))
        self.assertEqual(gate.verdict, "incomplete")
        self.assertEqual(gate.details["missing_languages"], ["mixed"])
        no_tokens = er.parse_utterances(make_corpus(tech_tokens=0), "test")
        gate = er.gate_asr_corpus(er.Evidence(utterances=no_tokens))
        self.assertEqual(gate.verdict, "incomplete")

    def test_human_review_gates(self):
        corpus = er.parse_utterances(make_corpus(), "test")
        ids = [u.id for u in corpus]
        evidence = er.Evidence(
            utterances=corpus,
            review_items=er.parse_review_items(make_review(49, utterance_ids=ids), "test"),
        )
        self.assertEqual(er.gate_human_review(evidence).verdict, "incomplete")
        evidence.review_items = er.parse_review_items(
            make_review(50, mixed_dev=24, utterance_ids=ids), "test"
        )
        gate = er.gate_human_review(evidence)
        self.assertEqual(gate.verdict, "incomplete")
        evidence.review_items = er.parse_review_items(
            make_review(50, critical=1, utterance_ids=ids), "test"
        )
        gate = er.gate_human_review(evidence)
        self.assertEqual(gate.verdict, "fail")
        self.assertEqual(gate.details["critical_item_ids"], ["r-000"])
        evidence.review_items = er.parse_review_items(
            make_review(50, utterance_ids=ids), "test"
        )
        self.assertEqual(er.gate_human_review(evidence).verdict, "pass")

    def test_review_linkage_rejects_foreign_utterance(self):
        corpus = make_corpus()
        with tempfile.TemporaryDirectory() as folder:
            corpus_path = Path(folder) / "corpus.json"
            corpus_path.write_text(json.dumps(corpus), encoding="utf-8")
            review_path = Path(folder) / "review.json"
            review_path.write_text(
                json.dumps(make_review(50, utterance_ids=["u-9999"])),
                encoding="utf-8",
            )
            args = er.build_parser().parse_args(
                ["--corpus", str(corpus_path), "--human-review", str(review_path)]
            )
            with self.assertRaises(er.EvidenceError):
                er.collect_evidence(args)

    def test_latency_gates(self):
        config = make_config()
        samples = er.parse_latency_samples(make_latency(299), "test")
        evidence = er.Evidence(
            reference_configuration=config, latency_samples=samples
        )
        self.assertEqual(er.gate_latency(evidence).verdict, "incomplete")
        samples = er.parse_latency_samples(make_latency(300), "test")
        evidence = er.Evidence(
            reference_configuration=config, latency_samples=samples
        )
        gate = er.gate_latency(evidence)
        self.assertEqual(gate.verdict, "pass")
        self.assertAlmostEqual(gate.details["p50_s"], 0.4)
        self.assertAlmostEqual(gate.details["p95_s"], 0.4)

    def test_latency_p95_failure(self):
        samples = er.parse_latency_samples(
            make_latency(300, low=0.4, high=1.2, high_count=20), "test"
        )
        evidence = er.Evidence(
            reference_configuration=make_config(), latency_samples=samples
        )
        gate = er.gate_latency(evidence)
        self.assertEqual(gate.verdict, "fail")
        self.assertAlmostEqual(gate.details["p95_s"], 1.2)
        self.assertAlmostEqual(gate.details["p50_s"], 0.4)

    def test_latency_requires_warm_config(self):
        samples = er.parse_latency_samples(make_latency(300), "test")
        evidence = er.Evidence(
            reference_configuration=make_config(warm_cold="cold"),
            latency_samples=samples,
        )
        self.assertEqual(er.gate_latency(evidence).verdict, "incomplete")
        evidence = er.Evidence(latency_samples=samples)
        self.assertEqual(er.gate_latency(evidence).verdict, "incomplete")

    def test_latency_rejects_out_of_condition_duration(self):
        samples = make_latency(300)
        samples[0]["utterance_duration_s"] = 2.0
        evidence = er.Evidence(
            reference_configuration=make_config(),
            latency_samples=er.parse_latency_samples(samples, "test"),
        )
        gate = er.gate_latency(evidence)
        self.assertEqual(gate.verdict, "incomplete")
        self.assertEqual(gate.details["out_of_condition_sample_ids"], ["l-000"])
        self.assertEqual(er.gate_trigger_capture(evidence).verdict, "incomplete")
        self.assertEqual(er.gate_trigger_strip(evidence).verdict, "incomplete")

    def test_trigger_gates_pass_and_fail(self):
        evidence = er.Evidence(
            reference_configuration=make_config(),
            latency_samples=er.parse_latency_samples(make_latency(300), "test"),
        )
        capture = er.gate_trigger_capture(evidence)
        strip = er.gate_trigger_strip(evidence)
        self.assertEqual(capture.verdict, "pass")
        self.assertEqual(strip.verdict, "pass")
        self.assertEqual(capture.details["observed"]["max_ms"], 30.0)
        self.assertEqual(strip.details["observed"]["max_ms"], 80.0)
        samples = make_latency(300)
        samples[0]["trigger_to_capture_ms"] = 50.0
        samples[1]["trigger_to_strip_ms"] = 140.0
        evidence = er.Evidence(
            reference_configuration=make_config(),
            latency_samples=er.parse_latency_samples(samples, "test"),
        )
        self.assertEqual(er.gate_trigger_capture(evidence).verdict, "fail")
        self.assertEqual(er.gate_trigger_strip(evidence).verdict, "fail")
        self.assertEqual(er.gate_latency(evidence).verdict, "pass")

    def test_trigger_gates_missing_measurement_incomplete(self):
        samples = make_latency(300)
        for sample in samples:
            del sample["trigger_to_capture_ms"]
        del samples[5]["trigger_to_strip_ms"]
        evidence = er.Evidence(
            reference_configuration=make_config(),
            latency_samples=er.parse_latency_samples(samples, "test"),
        )
        capture = er.gate_trigger_capture(evidence)
        self.assertEqual(capture.verdict, "incomplete")
        self.assertEqual(len(capture.details["missing_sample_ids"]), 300)
        strip = er.gate_trigger_strip(evidence)
        self.assertEqual(strip.verdict, "incomplete")
        self.assertEqual(strip.details["missing_sample_ids"], ["l-005"])
        self.assertEqual(er.gate_latency(evidence).verdict, "pass")

    def test_first_syllable_gates(self):
        trials = er.parse_first_syllable_trials(make_trials(199), "test")
        self.assertEqual(
            er.gate_first_syllable(er.Evidence(first_syllable_trials=trials)).verdict,
            "incomplete",
        )
        trials = er.parse_first_syllable_trials(make_trials(200), "test")
        self.assertEqual(
            er.gate_first_syllable(er.Evidence(first_syllable_trials=trials)).verdict,
            "pass",
        )
        trials = er.parse_first_syllable_trials(make_trials(200, losses={7}), "test")
        gate = er.gate_first_syllable(er.Evidence(first_syllable_trials=trials))
        self.assertEqual(gate.verdict, "fail")
        self.assertEqual(gate.details["loss_ids"], ["f-007"])
        trials = er.parse_first_syllable_trials(make_trials(200, speakers=1), "test")
        self.assertEqual(
            er.gate_first_syllable(er.Evidence(first_syllable_trials=trials)).verdict,
            "incomplete",
        )

    def test_first_syllable_requires_level_and_offset_spread(self):
        trials = er.parse_first_syllable_trials(
            make_trials(200, levels=("normal",)), "test"
        )
        gate = er.gate_first_syllable(er.Evidence(first_syllable_trials=trials))
        self.assertEqual(gate.verdict, "incomplete")
        self.assertEqual(gate.details["voice_levels"], 1)
        trials = er.parse_first_syllable_trials(
            make_trials(200, offsets=(0.0,)), "test"
        )
        gate = er.gate_first_syllable(er.Evidence(first_syllable_trials=trials))
        self.assertEqual(gate.verdict, "incomplete")
        self.assertEqual(gate.details["offsets_ms"], 1)

    def test_first_syllable_condition_fields_required(self):
        with self.assertRaises(er.EvidenceError):
            er.parse_first_syllable_trials(
                [{"id": "f-0", "speaker_id": "s", "lost": False}], "test"
            )
        with self.assertRaises(er.EvidenceError):
            er.parse_first_syllable_trials(
                [{"id": "f-0", "speaker_id": "s", "voice_level": "soft",
                  "offset_ms": -1.0, "lost": False}],
                "test",
            )

    def test_insertion_gates(self):
        attempts = er.parse_insertion_attempts(make_attempts(), "test")
        gate = er.gate_insertion(er.Evidence(insertion_attempts=attempts))
        self.assertEqual(gate.verdict, "pass")
        self.assertEqual(gate.details["eligible"], 2000)
        self.assertEqual(gate.details["success_rate"], 1.0)

    def test_insertion_success_boundary(self):
        attempts = er.parse_insertion_attempts(
            make_attempts(fail_ids={"i-00000", "i-00001"}), "test"
        )
        gate = er.gate_insertion(er.Evidence(insertion_attempts=attempts))
        self.assertEqual(gate.details["success_rate"], 0.999)
        self.assertEqual(gate.verdict, "pass")
        attempts = er.parse_insertion_attempts(
            make_attempts(fail_ids={"i-00000", "i-00001", "i-00002"}), "test"
        )
        gate = er.gate_insertion(er.Evidence(insertion_attempts=attempts))
        self.assertEqual(gate.verdict, "fail")

    def test_insertion_safety_failure_always_fails(self):
        attempts = er.parse_insertion_attempts(
            make_attempts(safety={"i-00010": "wrong_target"}), "test"
        )
        gate = er.gate_insertion(er.Evidence(insertion_attempts=attempts))
        self.assertEqual(gate.verdict, "fail")
        self.assertEqual(gate.details["safety_failure_ids"], ["i-00010"])
        short = er.parse_insertion_attempts(
            make_attempts(per_mode=25, modes=("textedit",), safety={"i-00010": "unintended_submit"}),
            "test",
        )
        gate = er.gate_insertion(er.Evidence(insertion_attempts=short))
        self.assertEqual(gate.verdict, "fail")

    def test_insertion_mode_minimums(self):
        attempts = make_attempts(per_mode=250)
        for attempt in attempts:
            if attempt["target_mode"] == "safari_textarea":
                attempt["eligible"] = False
                attempt["outcome"] = "recovered"
                attempt["recovery_reason"] = "other"
                attempt.pop("success")
                break
        attempts.append(
            {
                "id": "i-extra",
                "target_mode": "textedit",
                "eligible": True,
                "outcome": "inserted",
                "success": True,
            }
        )
        gate = er.gate_insertion(
            er.Evidence(insertion_attempts=er.parse_insertion_attempts(attempts, "test"))
        )
        self.assertEqual(gate.verdict, "incomplete")
        self.assertEqual(
            gate.details["modes_below_minimum"], ["safari_textarea"]
        )
        attempts = make_attempts(per_mode=50)
        gate = er.gate_insertion(
            er.Evidence(insertion_attempts=er.parse_insertion_attempts(attempts, "test"))
        )
        self.assertEqual(gate.verdict, "incomplete")

    def test_coverage_gate_and_recovery_only_flag(self):
        attempts = er.parse_insertion_attempts(
            make_attempts(per_mode=250, ineligible_per_mode=10), "test"
        )
        gate = er.gate_coverage(er.Evidence(insertion_attempts=attempts))
        self.assertEqual(gate.verdict, "pass")
        coverage = er.coverage_by_mode(attempts)
        stats = coverage["textedit"]
        self.assertEqual(stats["attempts"], 260)
        self.assertAlmostEqual(stats["clipboard_recovery_rate"], round(10 / 260, 6))
        self.assertEqual(stats["recovery_reasons"]["target_identity"], 10)
        self.assertTrue(stats["observed_automatic_insertion"])
        self.assertEqual(stats["validated_support"], "unknown")

    def test_validated_support_requires_explicit_evidence(self):
        attempts = er.parse_insertion_attempts(make_attempts(), "test")
        coverage = er.coverage_by_mode(attempts)
        self.assertTrue(coverage["textedit"]["observed_automatic_insertion"])
        self.assertEqual(coverage["textedit"]["validated_support"], "unknown")
        validations = er.parse_target_validations(
            make_target_validations(modes=("textedit",)), "test"
        )
        coverage = er.coverage_by_mode(attempts, validations)
        self.assertEqual(
            coverage["textedit"]["validated_support"], "validated"
        )
        self.assertEqual(
            coverage["iterm2_shell"]["validated_support"], "unknown"
        )
        rejected = er.parse_target_validations(
            make_target_validations(modes=("textedit",), validated=False), "test"
        )
        coverage = er.coverage_by_mode(attempts, rejected)
        self.assertEqual(
            coverage["textedit"]["validated_support"], "not_validated"
        )

    def test_conflicting_validation_stays_not_validated(self):
        validations = er.parse_target_validations(
            [
                {"id": "tv-0", "target_mode": "textedit", "validated": True},
                {"id": "tv-1", "target_mode": "textedit", "validated": False},
            ],
            "test",
        )
        self.assertEqual(
            er.validated_support_by_mode(validations)["textedit"], False
        )

    def test_coverage_missing_mode_incomplete(self):
        attempts = er.parse_insertion_attempts(
            make_attempts(per_mode=250, modes=er.TARGET_MODES[:-1]), "test"
        )
        gate = er.gate_coverage(er.Evidence(insertion_attempts=attempts))
        self.assertEqual(gate.verdict, "incomplete")
        self.assertEqual(gate.details["missing_modes"], ["chrome_textarea"])

    def test_recovery_only_mode_not_supported(self):
        attempts = make_attempts(per_mode=250)
        for attempt in attempts:
            if attempt["target_mode"] == "iterm2_shell":
                attempt["eligible"] = False
                attempt["outcome"] = "recovered"
                attempt["recovery_reason"] = "post_release_mutation"
                attempt.pop("success", None)
        parsed = er.parse_insertion_attempts(attempts, "test")
        coverage = er.coverage_by_mode(parsed)
        self.assertFalse(coverage["iterm2_shell"]["observed_automatic_insertion"])
        self.assertEqual(coverage["iterm2_shell"]["automatic_insertion_rate"], 0.0)
        self.assertEqual(coverage["iterm2_shell"]["validated_support"], "unknown")

    def test_attempt_consistency_validation(self):
        bad = [
            {
                "id": "i-0",
                "target_mode": "textedit",
                "eligible": True,
                "outcome": "recovered",
                "success": True,
                "recovery_reason": "other",
            }
        ]
        with self.assertRaises(er.EvidenceError):
            er.parse_insertion_attempts(bad, "test")
        missing_reason = [
            {
                "id": "i-0",
                "target_mode": "textedit",
                "eligible": False,
                "outcome": "recovered",
            }
        ]
        with self.assertRaises(er.EvidenceError):
            er.parse_insertion_attempts(missing_reason, "test")
        mismatched_safety = [
            {
                "id": "i-0",
                "target_mode": "textedit",
                "eligible": False,
                "outcome": "inserted",
                "safety_failure": "duplicate_delivery",
            }
        ]
        with self.assertRaises(er.EvidenceError):
            er.parse_insertion_attempts(mismatched_safety, "test")

    def test_duplicate_ids_rejected(self):
        records = [make_utterance(0), make_utterance(0)]
        with self.assertRaises(er.EvidenceError):
            er.parse_utterances(records, "test")

    def test_overall_verdict_precedence(self):
        evidence = full_evidence()
        self.assertEqual(er.evaluate(evidence)["verdict"], "pass")
        evidence.latency_samples = None
        self.assertEqual(er.evaluate(evidence)["verdict"], "incomplete")
        evidence.latency_samples = er.parse_latency_samples(
            make_latency(300, high=1.2, high_count=20), "test"
        )
        self.assertEqual(er.evaluate(evidence)["verdict"], "fail")


class CliTests(unittest.TestCase):
    def run_cli(self, argv):
        stdout = io.StringIO()
        stderr = io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            code = er.main(argv)
        return code, stdout.getvalue(), stderr.getvalue()

    def write_json(self, folder, name, data):
        path = Path(folder) / name
        path.write_text(json.dumps(data), encoding="utf-8")
        return path

    def test_full_document_passes(self):
        corpus = make_corpus()
        document = {
            "schema": er.EVALUATION_SCHEMA,
            "reference_configuration": make_config(),
            "utterances": corpus,
            "human_review": make_review(utterance_ids=[u["id"] for u in corpus]),
            "latency_samples": make_latency(),
            "first_syllable_trials": make_trials(),
            "insertion_attempts": make_attempts(),
            "target_validation": make_target_validations(),
        }
        with tempfile.TemporaryDirectory() as folder:
            path = self.write_json(folder, "run.json", document)
            report_path = Path(folder) / "report.json"
            code, stdout, stderr = self.run_cli(
                ["--input", str(path), "--format", "json", "--output", str(report_path)]
            )
            self.assertEqual(code, 0, stderr)
            report = json.loads(stdout)
            self.assertEqual(report["verdict"], "pass")
            self.assertEqual(report["schema"], er.REPORT_SCHEMA)
            self.assertEqual(
                report["coverage"]["per_target_mode"]["textedit"]["validated_support"],
                "validated",
            )
            self.assertIn("not_evaluated", report["scope"])
            self.assertIn("VAL-009", report["scope"]["not_evaluated"])
            persisted = json.loads(report_path.read_text())
            self.assertEqual(persisted["verdict"], "pass")

    def test_missing_sections_incomplete_exit(self):
        document = {"schema": er.EVALUATION_SCHEMA, "reference_configuration": make_config()}
        with tempfile.TemporaryDirectory() as folder:
            path = self.write_json(folder, "run.json", document)
            code, stdout, _ = self.run_cli(["--input", str(path), "--format", "json"])
            self.assertEqual(code, 2)
            report = json.loads(stdout)
            self.assertEqual(report["verdict"], "incomplete")
            self.assertEqual(report["gates"]["asr_corpus"]["verdict"], "incomplete")

    def test_failing_gate_exit_code(self):
        corpus = make_corpus()
        document = {
            "schema": er.EVALUATION_SCHEMA,
            "reference_configuration": make_config(),
            "utterances": corpus,
            "human_review": make_review(critical=2, utterance_ids=[u["id"] for u in corpus]),
            "latency_samples": make_latency(),
            "first_syllable_trials": make_trials(),
            "insertion_attempts": make_attempts(),
        }
        with tempfile.TemporaryDirectory() as folder:
            path = self.write_json(folder, "run.json", document)
            code, stdout, _ = self.run_cli(["--input", str(path), "--format", "json"])
            self.assertEqual(code, 1)
            report = json.loads(stdout)
            self.assertEqual(report["verdict"], "fail")
            self.assertEqual(report["gates"]["human_review"]["verdict"], "fail")

    def test_separate_section_files_and_jsonl(self):
        corpus = make_corpus()
        with tempfile.TemporaryDirectory() as folder:
            config_path = self.write_json(folder, "config.json", make_config())
            corpus_path = Path(folder) / "corpus.jsonl"
            corpus_path.write_text(
                "\n".join(json.dumps(u) for u in corpus) + "\n", encoding="utf-8"
            )
            review_path = self.write_json(
                folder, "review.json",
                {"human_review": make_review(utterance_ids=[u["id"] for u in corpus])},
            )
            latency_path = self.write_json(folder, "latency.json", make_latency())
            trials_path = self.write_json(folder, "trials.json", make_trials())
            attempts_path = Path(folder) / "attempts.jsonl"
            attempts_path.write_text(
                "\n".join(json.dumps(a) for a in make_attempts()) + "\n",
                encoding="utf-8",
            )
            code, stdout, stderr = self.run_cli(
                [
                    "--config", str(config_path),
                    "--corpus", str(corpus_path),
                    "--human-review", str(review_path),
                    "--latency", str(latency_path),
                    "--first-syllable", str(trials_path),
                    "--insertion", str(attempts_path),
                    "--format", "json",
                ]
            )
            self.assertEqual(code, 0, stderr)
            self.assertEqual(json.loads(stdout)["verdict"], "pass")

    def test_report_never_contains_transcript_text(self):
        corpus = make_corpus(ko=1, en=1, mixed=1, tech_tokens=1)
        corpus[0]["reference"] = SECRET
        corpus[0]["hypothesis"] = SECRET
        corpus[0]["technical_tokens"] = [{"token": "TokenShouldNotLeak9"}]
        document = {
            "schema": er.EVALUATION_SCHEMA,
            "reference_configuration": make_config(),
            "utterances": corpus,
            "human_review": make_review(3, mixed_dev=1, utterance_ids=[u["id"] for u in corpus]),
            "latency_samples": make_latency(300),
            "first_syllable_trials": make_trials(200),
            "insertion_attempts": make_attempts(),
        }
        with tempfile.TemporaryDirectory() as folder:
            path = self.write_json(folder, "run.json", document)
            report_path = Path(folder) / "report.json"
            for fmt in ("json", "text"):
                code, stdout, stderr = self.run_cli(
                    ["--input", str(path), "--format", fmt, "--output", str(report_path)]
                )
                self.assertIn(code, (0, 2))
                for channel in (stdout, stderr, report_path.read_text()):
                    self.assertNotIn("SECRET_SENTENCE_ZX9", channel)
                    self.assertNotIn("TokenShouldNotLeak9", channel)

    def test_malformed_json_input_error(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "bad.json"
            path.write_text("{not json", encoding="utf-8")
            code, _, stderr = self.run_cli(["--input", str(path)])
            self.assertEqual(code, 3)
            self.assertIn("invalid JSON", stderr)

    def test_wrong_schema_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = self.write_json(folder, "run.json", {"schema": "other/9"})
            code, _, stderr = self.run_cli(["--input", str(path)])
            self.assertEqual(code, 3)
            self.assertIn("schema", stderr)

    def test_missing_file_input_error(self):
        code, _, stderr = self.run_cli(["--input", "/nonexistent/eval.json"])
        self.assertEqual(code, 3)

    def test_text_format_renders(self):
        document = {"schema": er.EVALUATION_SCHEMA, "reference_configuration": make_config()}
        with tempfile.TemporaryDirectory() as folder:
            path = self.write_json(folder, "run.json", document)
            code, stdout, _ = self.run_cli(["--input", str(path)])
            self.assertEqual(code, 2)
            self.assertIn("verdict: incomplete", stdout)
            self.assertIn("gate latency: incomplete", stdout)
            self.assertIn("not complete v1 release readiness", stdout)


if __name__ == "__main__":
    unittest.main()
