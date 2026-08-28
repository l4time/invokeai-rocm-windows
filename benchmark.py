#!/usr/bin/env python3
"""Retry one InvokeAI queue item and record matched generation timings."""

from __future__ import annotations

import argparse
import copy
import json
import re
import statistics
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Any


TERMINAL_STATUSES = {"completed", "failed", "canceled"}
NODE_RE = re.compile(
    r"^\s*(\S+)\s+(\d+)\s+([\d.]+)s\s+([+-]?[\d.]+)G\s*$"
)
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
PROGRESS_RE = re.compile(
    r"(?P<done>\d+)/(?P<total>\d+)\s*\[[^\]\r\n]*?,\s*"
    r"(?P<rate>[\d.]+)\s*(?P<unit>it/s|s/it)\]"
)
PROMPT_VARIATIONS = (
    "soft golden-hour rim light, distant pine forest",
    "cool moonlit atmosphere, thin clouds over the peaks",
    "early-morning mist, glassy reflections on the water",
    "dramatic storm light, wind moving through the grass",
    "warm autumn palette, scattered amber leaves",
    "clear winter air, fresh snow along the shoreline",
    "gentle spring rain, small ripples across the lake",
    "blue-hour lighting, distant village lights",
    "high-contrast afternoon sun, crisp mountain shadows",
    "pastel dawn sky, low fog between the trees",
    "cinematic backlight, subtle haze above the water",
    "overcast soft light, detailed rocks in the foreground",
    "late-summer sunlight, wildflowers beside the lake",
    "northern lights overhead, faint stars in the sky",
    "sunbeams through clouds, luminous water reflections",
    "quiet twilight, deep blue mountains in the distance",
)
RESOLUTION_VARIATIONS = (
    (1152, 896),
    (896, 1152),
    (1216, 832),
    (832, 1216),
    (1088, 960),
    (960, 1088),
    (1280, 832),
    (832, 1280),
    (1152, 960),
    (960, 1152),
    (1088, 1024),
    (1024, 1088),
    (1216, 896),
    (896, 1216),
)


def request_json(base_url: str, method: str, path: str, body: Any | None = None) -> Any:
    data = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}{path}",
        data=data,
        method=method,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"{method} {path} failed: HTTP {exc.code}: {detail}") from exc


def parse_timestamp(value: str | None) -> datetime | None:
    if not value:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def queue_seconds(item: dict[str, Any]) -> float | None:
    started = parse_timestamp(item.get("started_at"))
    completed = parse_timestamp(item.get("completed_at"))
    if started is None or completed is None:
        return None
    return (completed - started).total_seconds()


def extract_item_id(response: Any) -> int:
    if isinstance(response, dict):
        for key in ("item_id", "queue_item_id"):
            if isinstance(response.get(key), int):
                return response[key]
        item_ids = response.get("item_ids")
        if isinstance(item_ids, list) and item_ids and isinstance(item_ids[0], int):
            return item_ids[0]
        queue_items = response.get("queue_items")
        if isinstance(queue_items, list) and queue_items:
            return extract_item_id(queue_items[0])
    raise RuntimeError(f"Could not find the new item id in retry response: {response!r}")


def parse_log_stats(
    log_path: Path | None, session_id: str, expected_steps: int
) -> dict[str, Any] | None:
    if log_path is None or not log_path.exists():
        return None
    raw = log_path.read_bytes()
    if raw.startswith((b"\xff\xfe", b"\xfe\xff")) or b"\x00" in raw[:1000]:
        text = raw.decode("utf-16", errors="replace")
    else:
        text = raw.decode("utf-8", errors="replace")
    text = ANSI_RE.sub("", text)
    markers = list(
        re.finditer(rf"Graph stats:\s*{re.escape(session_id)}", text)
    )
    if not markers:
        return None
    marker = markers[-1]
    progress_block = text[max(0, marker.start() - 40000) : marker.start()]
    block = text[marker.start() : marker.start() + 12000]
    stats: dict[str, Any] = {"session_id": session_id, "nodes": {}}
    completed_progress = [
        match
        for match in PROGRESS_RE.finditer(progress_block)
        if int(match.group("done")) == expected_steps
        and int(match.group("total")) == expected_steps
    ]
    if completed_progress:
        progress = completed_progress[-1]
        rate = float(progress.group("rate"))
        stats["sampler_iterations_per_second"] = (
            rate if progress.group("unit") == "it/s" else 1 / rate
        )
    graph_headers_seen = 0
    for line in block.splitlines():
        if "Graph stats:" in line:
            graph_headers_seen += 1
            if graph_headers_seen > 1:
                break
        node_match = NODE_RE.match(line)
        if node_match:
            node_type, calls, seconds, peak_vram = node_match.groups()
            stats["nodes"][node_type] = {
                "calls": int(calls),
                "seconds": float(seconds),
                "vram_gb": float(peak_vram),
            }
        if line.startswith("TOTAL GRAPH EXECUTION TIME:"):
            stats["execution_seconds"] = float(line.split(":", 1)[1].strip().removesuffix("s"))
        elif line.startswith("TOTAL GRAPH WALL TIME:"):
            stats["wall_seconds"] = float(line.split(":", 1)[1].strip().removesuffix("s"))
    return stats if "execution_seconds" in stats else None


def generation_details(graph: dict[str, Any]) -> dict[str, Any]:
    denoise_nodes = [
        node
        for node in graph.get("nodes", {}).values()
        if node.get("type") in {"krea2_denoise", "anima_denoise"}
    ]
    if len(denoise_nodes) != 1:
        raise RuntimeError(
            f"Expected exactly one supported denoise node, found {len(denoise_nodes)}"
        )
    denoise = denoise_nodes[0]
    details: dict[str, Any] = {
        "width": int(denoise["width"]),
        "height": int(denoise["height"]),
        "pixels": int(denoise["width"]) * int(denoise["height"]),
        "steps": int(denoise["steps"]),
        "batch_size": 1,
    }
    noise_nodes = [
        node
        for node in graph.get("nodes", {}).values()
        if node.get("type") == "noise"
    ]
    if len(noise_nodes) == 1 and "batch_size" in noise_nodes[0]:
        details["batch_size"] = int(noise_nodes[0]["batch_size"])
    return details


def add_throughput(item: dict[str, Any]) -> None:
    stats = item.get("performance_stats") or {}
    nodes = stats.get("nodes") or {}
    denoise_seconds = None
    for node_type in ("krea2_denoise", "anima_denoise"):
        if node_type in nodes:
            denoise_seconds = nodes[node_type].get("seconds")
            break
    details = item["benchmark_variation"]
    details["denoise_seconds"] = denoise_seconds
    details["effective_denoise_iterations_per_second"] = (
        details["steps"] / denoise_seconds
        if denoise_seconds is not None and denoise_seconds > 0
        else None
    )
    details["sampler_iterations_per_second"] = stats.get(
        "sampler_iterations_per_second"
    )


def enqueue_clone_and_wait(
    base_url: str,
    source_item: dict[str, Any],
    poll_seconds: float,
    timeout_seconds: float,
    variation: str,
    variation_index: int,
    main_model: dict[str, Any] | None,
    qwen3_vl_encoder_model: dict[str, Any] | None,
    qwen3_encoder_model: dict[str, Any] | None,
    vae_model: dict[str, Any] | None,
) -> dict[str, Any]:
    submitted_at = time.perf_counter()
    graph = copy.deepcopy(source_item["session"]["graph"])
    if main_model is not None:
        loader_nodes_updated = 0
        for node in graph.get("nodes", {}).values():
            if node.get("type") in {"krea2_model_loader", "anima_model_loader"}:
                node["model"] = main_model
                loader_nodes_updated += 1
            elif node.get("type") == "core_metadata" and "model" in node:
                node["model"] = main_model
        if loader_nodes_updated != 1:
            raise RuntimeError(
                "Expected exactly one supported model loader when overriding the "
                f"main model, found {loader_nodes_updated}"
            )
    if qwen3_vl_encoder_model is not None:
        loader_nodes_updated = 0
        for node in graph.get("nodes", {}).values():
            if node.get("type") == "krea2_model_loader":
                node["qwen3_vl_encoder_model"] = qwen3_vl_encoder_model
                loader_nodes_updated += 1
            elif node.get("type") == "core_metadata" and "qwen3_vl_encoder" in node:
                node["qwen3_vl_encoder"] = qwen3_vl_encoder_model
        if loader_nodes_updated != 1:
            raise RuntimeError(
                "Expected exactly one Krea-2 model loader when overriding the "
                f"Qwen3-VL encoder, found {loader_nodes_updated}"
            )
    if qwen3_encoder_model is not None:
        loader_nodes_updated = 0
        for node in graph.get("nodes", {}).values():
            if node.get("type") == "anima_model_loader":
                node["qwen3_encoder_model"] = qwen3_encoder_model
                loader_nodes_updated += 1
            elif node.get("type") == "core_metadata" and "qwen3_encoder" in node:
                node["qwen3_encoder"] = qwen3_encoder_model
        if loader_nodes_updated != 1:
            raise RuntimeError(
                "Expected exactly one Anima model loader when overriding the "
                f"Qwen3 encoder, found {loader_nodes_updated}"
            )
    if vae_model is not None:
        loader_nodes_updated = 0
        for node in graph.get("nodes", {}).values():
            if node.get("type") in {"krea2_model_loader", "anima_model_loader"}:
                node["vae_model"] = vae_model
                loader_nodes_updated += 1
            elif node.get("type") == "core_metadata" and "vae" in node:
                node["vae"] = vae_model
        if loader_nodes_updated != 1:
            raise RuntimeError(
                "Expected exactly one supported model loader when overriding the "
                f"VAE, found {loader_nodes_updated}"
            )
    variation_details: dict[str, Any] = {"kind": variation}
    if variation == "seed":
        seed_nodes = [
            node
            for node in graph.get("nodes", {}).values()
            if node.get("type") == "integer" and "seed" in node.get("id", "").lower()
        ]
        if len(seed_nodes) != 1:
            raise RuntimeError(
                f"Expected exactly one seed integer node, found {len(seed_nodes)}"
            )
        seed = (int(seed_nodes[0]["value"]) + variation_index + 1) % (2**32)
        seed_nodes[0]["value"] = seed
        variation_details["seed"] = seed
    elif variation == "prompt":
        prompt_nodes = [
            node
            for node in graph.get("nodes", {}).values()
            if node.get("type") == "string"
            and "positive_prompt" in node.get("id", "").lower()
        ]
        if len(prompt_nodes) != 1:
            raise RuntimeError(
                f"Expected exactly one positive prompt string node, found {len(prompt_nodes)}"
            )
        prompt_suffix = PROMPT_VARIATIONS[variation_index % len(PROMPT_VARIATIONS)]
        prompt_nodes[0]["value"] = f"{prompt_nodes[0]['value']}, {prompt_suffix}"
        variation_details["prompt"] = prompt_nodes[0]["value"]
    elif variation == "resolution":
        if variation_index >= len(RESOLUTION_VARIATIONS):
            raise RuntimeError(
                f"Resolution mode supports at most {len(RESOLUTION_VARIATIONS)} total runs"
            )
        width, height = RESOLUTION_VARIATIONS[variation_index]
        for node in graph.get("nodes", {}).values():
            if node.get("type") == "noise":
                node["width"] = width
                node["height"] = height
            elif node.get("type") == "sdxl_compel_prompt":
                node["original_width"] = width
                node["original_height"] = height
                node["target_width"] = width
                node["target_height"] = height
            elif node.get("type") in {"krea2_denoise", "anima_denoise"}:
                node["width"] = width
                node["height"] = height
            elif node.get("type") == "core_metadata":
                node["width"] = width
                node["height"] = height
        variation_details["width"] = width
        variation_details["height"] = height
        variation_details["pixels"] = width * height
    elif variation != "fixed":
        raise RuntimeError(f"Unsupported variation mode: {variation}")
    variation_details.update(generation_details(graph))

    batch = {
        "origin": source_item.get("origin"),
        "destination": source_item.get("destination"),
        "data": None,
        "graph": graph,
        "workflow": source_item.get("workflow"),
        "runs": 1,
    }
    response = request_json(
        base_url,
        "POST",
        "/api/v1/queue/default/enqueue_batch",
        {"batch": batch, "prepend": False},
    )
    item_id = extract_item_id(response)
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        item = request_json(base_url, "GET", f"/api/v1/queue/default/i/{item_id}")
        if item["status"] in TERMINAL_STATUSES:
            item["client_end_to_end_seconds"] = time.perf_counter() - submitted_at
            item["queue_processing_seconds"] = queue_seconds(item)
            item["benchmark_variation"] = variation_details
            return item
        time.sleep(poll_seconds)
    raise TimeoutError(f"Queue item {item_id} did not finish within {timeout_seconds}s")


def median(values: list[float | None]) -> float | None:
    clean = [value for value in values if value is not None]
    return statistics.median(clean) if clean else None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:9090")
    parser.add_argument("--source-item-id", type=int, required=True)
    parser.add_argument("--warmups", type=int, default=1)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--poll-seconds", type=float, default=0.25)
    parser.add_argument("--timeout-seconds", type=float, default=900)
    parser.add_argument(
        "--variation",
        choices=("prompt", "resolution", "seed", "fixed"),
        default="prompt",
        help=(
            "What changes between runs. The default changes only the positive prompt, "
            "forcing conditioning, denoising, and VAE decode while keeping model, seed, "
            "resolution, and generation settings fixed."
        ),
    )
    parser.add_argument(
        "--model-key",
        help="Override the main model in a cloned Krea-2 or Anima graph.",
    )
    parser.add_argument(
        "--qwen3-vl-encoder-key",
        help="Override the Qwen3-VL encoder in a cloned Krea-2 graph.",
    )
    parser.add_argument(
        "--qwen3-encoder-key",
        help="Override the Qwen3 encoder in a cloned Anima graph.",
    )
    parser.add_argument(
        "--vae-key",
        help="Override the VAE in a cloned Krea-2 or Anima graph.",
    )
    parser.add_argument("--log", type=Path, default=Path(__file__).with_name("invokeai.log"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.warmups < 0 or args.runs < 0 or args.warmups + args.runs == 0:
        parser.error("--warmups and --runs must be non-negative and include at least one run")
    if args.poll_seconds <= 0 or args.timeout_seconds <= 0:
        parser.error("--poll-seconds and --timeout-seconds must be positive")

    version = request_json(args.url, "GET", "/api/v1/app/version")
    source_item = request_json(
        args.url,
        "GET",
        f"/api/v1/queue/default/i/{args.source_item_id}",
    )
    if source_item["status"] != "completed":
        raise RuntimeError(
            f"Source queue item {args.source_item_id} must be completed, "
            f"not {source_item['status']}"
        )
    main_model = None
    if args.model_key:
        model_config = request_json(
            args.url,
            "GET",
            f"/api/v2/models/i/{args.model_key}",
        )
        if model_config.get("type") != "main":
            raise RuntimeError(
                f"Model {args.model_key} is "
                f"{model_config.get('type')!r}, not 'main'"
            )
        main_model = {
            key: model_config[key]
            for key in ("key", "hash", "name", "base", "type")
        }
    qwen3_vl_encoder_model = None
    if args.qwen3_vl_encoder_key:
        encoder_config = request_json(
            args.url,
            "GET",
            f"/api/v2/models/i/{args.qwen3_vl_encoder_key}",
        )
        if encoder_config.get("type") != "qwen3_vl_encoder":
            raise RuntimeError(
                f"Model {args.qwen3_vl_encoder_key} is "
                f"{encoder_config.get('type')!r}, not 'qwen3_vl_encoder'"
            )
        qwen3_vl_encoder_model = {
            key: encoder_config[key]
            for key in ("key", "hash", "name", "base", "type")
        }
    qwen3_encoder_model = None
    if args.qwen3_encoder_key:
        encoder_config = request_json(
            args.url,
            "GET",
            f"/api/v2/models/i/{args.qwen3_encoder_key}",
        )
        if encoder_config.get("type") != "qwen3_encoder":
            raise RuntimeError(
                f"Model {args.qwen3_encoder_key} is "
                f"{encoder_config.get('type')!r}, not 'qwen3_encoder'"
            )
        qwen3_encoder_model = {
            key: encoder_config[key]
            for key in ("key", "hash", "name", "base", "type")
        }
    vae_model = None
    if args.vae_key:
        vae_config = request_json(
            args.url,
            "GET",
            f"/api/v2/models/i/{args.vae_key}",
        )
        if vae_config.get("type") != "vae":
            raise RuntimeError(
                f"Model {args.vae_key} is "
                f"{vae_config.get('type')!r}, not 'vae'"
            )
        vae_model = {
            key: vae_config[key]
            for key in ("key", "hash", "name", "base", "type")
        }
    records: list[dict[str, Any]] = []
    total_runs = args.warmups + args.runs
    for index in range(total_runs):
        item = enqueue_clone_and_wait(
            args.url,
            source_item,
            args.poll_seconds,
            args.timeout_seconds,
            args.variation,
            index,
            main_model,
            qwen3_vl_encoder_model,
            qwen3_encoder_model,
            vae_model,
        )
        if item["status"] != "completed":
            raise RuntimeError(
                f"Queue item {item['item_id']} ended as {item['status']}: "
                f"{item.get('error_type')}: {item.get('error_message')}"
            )
        time.sleep(0.5)
        item["performance_stats"] = parse_log_stats(
            args.log,
            item["session_id"],
            item["benchmark_variation"]["steps"],
        )
        add_throughput(item)
        records.append(
            {
                "kind": "warmup" if index < args.warmups else "measured",
                "variation": item["benchmark_variation"],
                "item": item,
            }
        )
        throughput = item["benchmark_variation"]["sampler_iterations_per_second"]
        throughput_label = "sampler"
        if throughput is None:
            throughput = item["benchmark_variation"][
                "effective_denoise_iterations_per_second"
            ]
            throughput_label = "effective"
        throughput_text = (
            f"{throughput:.3f} it/s" if throughput is not None else "n/a it/s"
        )
        print(
            f"{records[-1]['kind']} {index + 1}/{total_runs}: "
            f"{item['benchmark_variation']['width']}x"
            f"{item['benchmark_variation']['height']} "
            f"item={item['item_id']} e2e={item['client_end_to_end_seconds']:.3f}s "
            f"queue={item['queue_processing_seconds']:.3f}s "
            f"{throughput_label}={throughput_text}"
        )

    measured = [record["item"] for record in records if record["kind"] == "measured"]
    warmup_items = [record["item"] for record in records if record["kind"] == "warmup"]
    node_types = sorted(
        {
            node_type
            for item in measured
            for node_type in ((item.get("performance_stats") or {}).get("nodes") or {})
        }
    )
    summary = {
        "first_request_after_start": (
            {
                "client_end_to_end_seconds": warmup_items[0][
                    "client_end_to_end_seconds"
                ],
                "queue_processing_seconds": warmup_items[0][
                    "queue_processing_seconds"
                ],
                "variation": warmup_items[0]["benchmark_variation"],
            }
            if warmup_items
            else None
        ),
        "client_end_to_end_median_seconds": median(
            [item["client_end_to_end_seconds"] for item in measured]
        ),
        "queue_processing_median_seconds": median(
            [item["queue_processing_seconds"] for item in measured]
        ),
        "graph_execution_median_seconds": median(
            [
                (item.get("performance_stats") or {}).get("execution_seconds")
                for item in measured
            ]
        ),
        "graph_wall_median_seconds": median(
            [(item.get("performance_stats") or {}).get("wall_seconds") for item in measured]
        ),
        "node_median_seconds": {
            node_type: median(
                [
                    ((item.get("performance_stats") or {}).get("nodes") or {})
                    .get(node_type, {})
                    .get("seconds")
                    for item in measured
                ]
            )
            for node_type in node_types
        },
        "measurements": [
            {
                "item_id": item["item_id"],
                "width": item["benchmark_variation"]["width"],
                "height": item["benchmark_variation"]["height"],
                "steps": item["benchmark_variation"]["steps"],
                "batch_size": item["benchmark_variation"]["batch_size"],
                "queue_processing_seconds": item["queue_processing_seconds"],
                "client_end_to_end_seconds": item["client_end_to_end_seconds"],
                "denoise_seconds": item["benchmark_variation"]["denoise_seconds"],
                "sampler_iterations_per_second": item["benchmark_variation"][
                    "sampler_iterations_per_second"
                ],
                "effective_denoise_iterations_per_second": item[
                    "benchmark_variation"
                ][
                    "effective_denoise_iterations_per_second"
                ],
            }
            for item in measured
        ],
    }
    resolution_labels = sorted(
        {
            (
                item["benchmark_variation"]["width"],
                item["benchmark_variation"]["height"],
            )
            for item in measured
        }
    )
    summary["throughput_by_resolution"] = {
        f"{width}x{height}": {
            "sampler_iterations_per_second_median": median(
                [
                    item["benchmark_variation"]["sampler_iterations_per_second"]
                    for item in measured
                    if item["benchmark_variation"]["width"] == width
                    and item["benchmark_variation"]["height"] == height
                ]
            ),
            "effective_denoise_iterations_per_second_median": median(
                [
                    item["benchmark_variation"][
                        "effective_denoise_iterations_per_second"
                    ]
                    for item in measured
                    if item["benchmark_variation"]["width"] == width
                    and item["benchmark_variation"]["height"] == height
                ]
            ),
        }
        for width, height in resolution_labels
    }
    end_to_end_values = [item["client_end_to_end_seconds"] for item in measured]
    queue_values = [item["queue_processing_seconds"] for item in measured]
    window = min(3, len(measured))
    first_end_to_end = median(end_to_end_values[:window])
    last_end_to_end = median(end_to_end_values[-window:])
    first_queue = median(queue_values[:window])
    last_queue = median(queue_values[-window:])
    summary["soak"] = {
        "measured_end_to_end_seconds": end_to_end_values,
        "measured_queue_seconds": queue_values,
        "first_window_runs": window,
        "first_end_to_end_median_seconds": first_end_to_end,
        "last_end_to_end_median_seconds": last_end_to_end,
        "last_vs_first_end_to_end_ratio": (
            last_end_to_end / first_end_to_end
            if first_end_to_end is not None and last_end_to_end is not None
            else None
        ),
        "first_queue_median_seconds": first_queue,
        "last_queue_median_seconds": last_queue,
        "last_vs_first_queue_ratio": (
            last_queue / first_queue
            if first_queue is not None and last_queue is not None
            else None
        ),
    }
    output = {
        "invokeai": version,
        "source_item_id": args.source_item_id,
        "source_item": source_item,
        "warmups": args.warmups,
        "runs": args.runs,
        "variation": args.variation,
        "main_model": main_model,
        "qwen3_vl_encoder_model": qwen3_vl_encoder_model,
        "qwen3_encoder_model": qwen3_encoder_model,
        "vae_model": vae_model,
        "summary": summary,
        "records": records,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
