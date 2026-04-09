#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
import statistics
import sys
import time
from dataclasses import dataclass
from typing import Any
from urllib import error, request


DEFAULT_PROMPT = (
    "Please explain in plain English what a Kubernetes Service does "
    "and why it matters in a cluster."
)


@dataclass
class RunResult:
    index: int
    prompt_tps: float
    gen_tps: float
    gen_ms: float
    wall_ms: float
    prompt_tokens: int
    predicted_tokens: int
    model_alias: str
    content: str


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("value must be greater than 0")
    return parsed


def non_negative_float(value: str) -> float:
    parsed = float(value)
    if parsed < 0:
        raise argparse.ArgumentTypeError("value must be greater than or equal to 0")
    return parsed


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Benchmark llama.cpp /completion throughput and print a README-ready Markdown row."
        )
    )
    parser.add_argument(
        "--url",
        default="http://127.0.0.1:8080/completion",
        help="Completion endpoint URL.",
    )
    parser.add_argument(
        "--warmup-runs",
        type=positive_int,
        default=1,
        help="Warm-up requests to ignore before measured runs.",
    )
    parser.add_argument(
        "--runs",
        type=positive_int,
        default=5,
        help="Measured requests.",
    )
    parser.add_argument(
        "--prompt",
        default=DEFAULT_PROMPT,
        help="Prompt text sent to /completion.",
    )
    parser.add_argument(
        "--n-predict",
        type=positive_int,
        default=128,
        help="Maximum tokens to generate per request.",
    )
    parser.add_argument(
        "--temperature",
        type=non_negative_float,
        default=0.1,
        help="Sampling temperature.",
    )
    parser.add_argument(
        "--ignore-eos",
        dest="ignore_eos",
        action="store_true",
        default=True,
        help="Ignore EOS while generating. Enabled by default.",
    )
    parser.add_argument(
        "--respect-eos",
        dest="ignore_eos",
        action="store_false",
        help="Stop on EOS instead of ignoring it.",
    )
    parser.add_argument(
        "--stop",
        action="append",
        default=[],
        help="Repeatable stop sequence. Omit entirely to match the default benchmark profile.",
    )
    parser.add_argument(
        "--timeout",
        type=non_negative_float,
        default=600.0,
        help="Per-request timeout in seconds.",
    )
    parser.add_argument(
        "--retry-attempts",
        type=positive_int,
        default=10,
        help="Retry attempts per request on transient failures.",
    )
    parser.add_argument(
        "--retry-delay",
        type=non_negative_float,
        default=1.0,
        help="Delay between retries in seconds.",
    )
    parser.add_argument(
        "--date",
        default=dt.date.today().isoformat(),
        help="Date used in the Markdown row.",
    )
    parser.add_argument(
        "--host-cpu",
        default="unknown",
        help="Host CPU label for the Markdown row.",
    )
    parser.add_argument(
        "--deployment",
        default="Docker Compose",
        help="Deployment label for the Markdown row.",
    )
    parser.add_argument(
        "--image-tag",
        default="unknown",
        help="Image tag for the Markdown row.",
    )
    parser.add_argument(
        "--model-file",
        default="gemma-4-E2B-it-Q4_K_M.gguf",
        help="Model filename shown in the Markdown row.",
    )
    parser.add_argument(
        "--notes",
        default="Local benchmark",
        help="Notes column for the Markdown row.",
    )
    parser.add_argument(
        "--show-response",
        action="store_true",
        help="Print the last completion content.",
    )
    return parser.parse_args()


def build_payload(args: argparse.Namespace) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "prompt": args.prompt,
        "n_predict": args.n_predict,
        "temperature": args.temperature,
        "ignore_eos": args.ignore_eos,
    }
    if args.stop:
        payload["stop"] = args.stop
    return payload


def post_json(url: str, payload: dict[str, Any], timeout: float) -> tuple[dict[str, Any], float]:
    data = json.dumps(payload).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    req = request.Request(url, data=data, headers=headers, method="POST")
    started = time.perf_counter()
    try:
        with request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
            status = resp.getcode()
    except error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        raise RuntimeError(f"HTTP {exc.code}: {body[:400]}") from exc
    except error.URLError as exc:
        raise RuntimeError(f"request failed: {exc.reason}") from exc

    elapsed_ms = (time.perf_counter() - started) * 1000.0
    try:
        parsed = json.loads(body)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"invalid JSON response: {body[:400]!r}") from exc

    if status != 200:
        raise RuntimeError(f"unexpected HTTP status {status}: {parsed}")

    return parsed, elapsed_ms


def run_once(
    index: int,
    args: argparse.Namespace,
    payload: dict[str, Any],
) -> RunResult:
    last_error: RuntimeError | None = None
    for attempt in range(1, args.retry_attempts + 1):
        try:
            parsed, wall_ms = post_json(args.url, payload, args.timeout)
            break
        except RuntimeError as exc:
            last_error = exc
            if attempt == args.retry_attempts:
                raise
            print(
                f"request {index} failed on attempt {attempt}/{args.retry_attempts}: {exc}",
                file=sys.stderr,
            )
            time.sleep(args.retry_delay)
    else:
        raise RuntimeError(str(last_error))

    timings = parsed.get("timings") or {}
    prompt_tps = float(timings["prompt_per_second"])
    gen_tps = float(timings["predicted_per_second"])
    gen_ms = float(timings["predicted_ms"])

    return RunResult(
        index=index,
        prompt_tps=prompt_tps,
        gen_tps=gen_tps,
        gen_ms=gen_ms,
        wall_ms=wall_ms,
        prompt_tokens=int(parsed.get("tokens_evaluated", 0)),
        predicted_tokens=int(parsed.get("tokens_predicted", 0)),
        model_alias=str(parsed.get("model", "unknown")),
        content=str(parsed.get("content", "")),
    )


def format_run(prefix: str, result: RunResult) -> str:
    return (
        f"{prefix} {result.index}: prompt={result.prompt_tps:.2f} tok/s, "
        f"gen={result.gen_tps:.2f} tok/s, gen_ms={result.gen_ms:.1f}, "
        f"prompt_tokens={result.prompt_tokens}, predicted_tokens={result.predicted_tokens}"
    )


def mean(values: list[float]) -> float:
    return statistics.mean(values) if values else 0.0


def markdown_row(args: argparse.Namespace, results: list[RunResult]) -> str:
    avg_gen_tps = mean([result.gen_tps for result in results])
    avg_prompt_tps = mean([result.prompt_tps for result in results])
    avg_gen_ms = mean([result.gen_ms for result in results])
    min_gen_tps = min(result.gen_tps for result in results)
    max_gen_tps = max(result.gen_tps for result in results)
    return (
        f"| {args.date} | {args.host_cpu} | {args.deployment} | {args.image_tag} | "
        f"{args.model_file} | {avg_gen_tps:.2f} | {min_gen_tps:.2f}-{max_gen_tps:.2f} | "
        f"{avg_prompt_tps:.2f} | {avg_gen_ms:.1f} ms | {args.notes} |"
    )


def print_summary(args: argparse.Namespace, results: list[RunResult]) -> None:
    avg_prompt_tps = mean([result.prompt_tps for result in results])
    avg_gen_tps = mean([result.gen_tps for result in results])
    avg_gen_ms = mean([result.gen_ms for result in results])
    avg_wall_ms = mean([result.wall_ms for result in results])
    avg_prompt_tokens = mean([float(result.prompt_tokens) for result in results])
    avg_predicted_tokens = mean([float(result.predicted_tokens) for result in results])
    min_gen_tps = min(result.gen_tps for result in results)
    max_gen_tps = max(result.gen_tps for result in results)
    effective_client_tps = (
        sum(result.predicted_tokens for result in results) * 1000.0 / sum(result.wall_ms for result in results)
    )

    print("\nSummary")
    print(f"- endpoint: {args.url}")
    print(f"- measured runs: {len(results)}")
    print(f"- model alias: {results[-1].model_alias}")
    print(f"- avg prompt throughput: {avg_prompt_tps:.2f} tok/s")
    print(f"- avg generation throughput: {avg_gen_tps:.2f} tok/s")
    print(f"- generation throughput range: {min_gen_tps:.2f}-{max_gen_tps:.2f} tok/s")
    print(f"- avg generation time: {avg_gen_ms:.1f} ms")
    print(f"- avg client round-trip time: {avg_wall_ms:.1f} ms")
    print(f"- avg prompt tokens: {avg_prompt_tokens:.1f}")
    print(f"- avg generated tokens: {avg_predicted_tokens:.1f}")
    print(f"- client-side effective generation throughput: {effective_client_tps:.2f} tok/s")

    if args.show_response:
        print("- last response:")
        print(results[-1].content.strip())

    print("\nMarkdown row")
    print(markdown_row(args, results))


def main() -> int:
    args = parse_args()
    payload = build_payload(args)

    print("Benchmark profile")
    print(f"- url: {args.url}")
    print(f"- warm-up runs: {args.warmup_runs}")
    print(f"- measured runs: {args.runs}")
    print(f"- n_predict: {args.n_predict}")
    print(f"- temperature: {args.temperature}")
    print(f"- ignore_eos: {str(args.ignore_eos).lower()}")
    print(f"- stop count: {len(args.stop)}")

    for run_index in range(1, args.warmup_runs + 1):
        result = run_once(run_index, args, payload)
        print(format_run("warm-up", result))

    measured_results: list[RunResult] = []
    for run_index in range(1, args.runs + 1):
        result = run_once(run_index, args, payload)
        measured_results.append(result)
        print(format_run("run", result))

    print_summary(args, measured_results)
    return 0


if __name__ == "__main__":
    sys.exit(main())