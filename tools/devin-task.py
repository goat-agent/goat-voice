#!/usr/bin/env python3
import argparse
import datetime as dt
import pathlib
import os
import signal
import json
import shutil
import subprocess
import sys

MODEL = "swe-2-max"
ROOT = pathlib.Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description="Run a bounded task with the free SWE-2 Max model")
    parser.add_argument("--resume", help="Resume an interrupted Devin session by ID")
    parser.add_argument("prompt", type=pathlib.Path, help="Task prompt file")
    args = parser.parse_args()
    prompt = args.prompt.resolve()
    if not prompt.is_file():
        parser.error(f"Prompt does not exist: {prompt}")
    binary = shutil.which("devin")
    if not binary:
        parser.error("Install and authenticate the Devin CLI first")
    try:
        listing = subprocess.run([binary, "models", "list", "--format", "json"], capture_output=True,
                                 text=True, timeout=60, check=True)
    except (subprocess.SubprocessError, OSError) as error:
        sys.exit(f"Could not verify model pricing; task was not started: {error}")
    try:
        families = json.loads(listing.stdout)["families"]
        models = [variant for family in families for variant in family["variants"]
                  if variant["model_uid"] == MODEL]
    except (ValueError, KeyError, TypeError):
        sys.exit("Unrecognized model listing; task was not started.")
    if len(models) != 1 or models[0].get("cost_tier") != "Free":
        sys.exit(f"{MODEL} is not unambiguously advertised as Free; task was not started.")
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    folder = ROOT / ".devin" / "runs"
    folder.mkdir(parents=True, exist_ok=True)
    log = folder / f"{stamp}-{prompt.stem}.log"
    command = [binary, "--model", MODEL, "--permission-mode", "dangerous", "--respect-workspace-trust",
               "false", "--prompt-file", str(prompt), "--export", str(log.with_suffix(".json")), "-p"]
    if args.resume:
        command.extend(["--resume", args.resume])
    print(f"{MODEL} · {models[0]['cost_tier']}\nTask log: {log}", flush=True)
    environment = os.environ.copy()
    developer_directory = pathlib.Path("/Applications/Xcode.app/Contents/Developer")
    if developer_directory.is_dir():
        environment.setdefault("DEVELOPER_DIR", str(developer_directory))
    with log.open("x") as output:
        process = subprocess.Popen(command, cwd=ROOT, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True, env=environment)
        try:
            return_code = process.wait(timeout=3600)
        except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            reason = "Interrupted" if isinstance(error, KeyboardInterrupt) else "60-minute limit reached"
            sys.exit(f"{reason}. Partial workspace edits may remain; inspect {log} before retrying.")
    print(f"Devin exited {return_code}. Log: {log}")
    return return_code


if __name__ == "__main__":
    sys.exit(main())
