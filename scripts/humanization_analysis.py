#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
from statistics import median

ROOT = Path(__file__).resolve().parent.parent
RESULTS = ROOT / "results"
DEFAULT_HISTORY_PATH = RESULTS / "humanization-history.jsonl"


def load_history(path=DEFAULT_HISTORY_PATH):
    if not path.exists():
        return []
    records = []
    for line in path.read_text(encoding="utf-8").splitlines():
        text = line.strip()
        if not text:
            continue
        try:
            records.append(json.loads(text))
        except json.JSONDecodeError:
            continue
    return records


def append_history_record(record, path=DEFAULT_HISTORY_PATH, max_records=1200):
    path.parent.mkdir(parents=True, exist_ok=True)
    records = load_history(path)
    records.append(record)
    if len(records) > max_records:
        records = records[-max_records:]
    path.write_text("".join(json.dumps(item, ensure_ascii=False, separators=(",", ":")) + "\n" for item in records), encoding="utf-8")
    return {
        "stored": True,
        "records": len(records),
        "path": str(path),
        "maxRecords": max_records,
    }


def analyze_history(records, host=None, instruction_key=None):
    filtered = []
    for record in records:
        if host and record.get("host") != host:
            continue
        if instruction_key and record.get("instructionKey") != instruction_key:
            continue
        filtered.append(record)

    groups = {}
    for record in filtered:
        key = record.get("instructionKey") or "default"
        groups.setdefault(key, []).append(record)

    analyzed_groups = [analyze_group(key, items) for key, items in sorted(groups.items())]
    analyzed_groups.sort(key=lambda item: item["sampleCount"], reverse=True)
    overall = build_overall_summary(analyzed_groups)
    return {
        "history": {
            "records": len(filtered),
            "groups": len(analyzed_groups),
            "host": host,
            "instructionKey": instruction_key,
        },
        "overall": overall,
        "groups": analyzed_groups,
    }


def analyze_group(key, records):
    user_speeds = collect_metric(records, "comparison.user.avgSpeedPxS")
    hid_speeds = collect_metric(records, "comparison.virtual.avgSpeedPxS")
    user_straightness = collect_metric(records, "comparison.user.straightness")
    hid_straightness = collect_metric(records, "comparison.virtual.straightness")
    user_turn = collect_metric(records, "comparison.user.turnJitter")
    hid_turn = collect_metric(records, "comparison.virtual.turnJitter")
    user_pauses = collect_metric(records, "comparison.user.pauses")
    hid_pauses = collect_metric(records, "comparison.virtual.pauses")
    user_points = collect_metric(records, "comparison.user.pointCount")
    hid_points = collect_metric(records, "comparison.virtual.pointCount")

    divergence = {
        "speedGapPxS": round_num(median_or_zero(hid_speeds) - median_or_zero(user_speeds)),
        "speedRatio": round_num(safe_ratio(median_or_zero(hid_speeds), median_or_zero(user_speeds))),
        "straightnessGap": round_num(median_or_zero(hid_straightness) - median_or_zero(user_straightness)),
        "turnJitterGap": round_num(median_or_zero(hid_turn) - median_or_zero(user_turn)),
        "pauseGap": round_num(median_or_zero(hid_pauses) - median_or_zero(user_pauses)),
        "pointCountGap": round_num(median_or_zero(hid_points) - median_or_zero(user_points)),
    }
    tuning = build_tuning(records, divergence)
    replay = build_replay_summary(records)
    quality = {
        "confidence": round_num(min(0.95, 0.32 + len(records) / 30.0)),
        "improving": improvement_signal(records),
    }
    return {
        "instructionKey": key,
        "sampleCount": len(records),
        "latestAt": max((record.get("ts") or record.get("generatedAt") or "") for record in records),
        "metrics": {
            "user": {
                "avgSpeedPxS": round_num(median_or_zero(user_speeds)),
                "straightness": round_num(median_or_zero(user_straightness)),
                "turnJitter": round_num(median_or_zero(user_turn)),
                "pauses": round_num(median_or_zero(user_pauses)),
                "pointCount": round_num(median_or_zero(user_points)),
            },
            "hid": {
                "avgSpeedPxS": round_num(median_or_zero(hid_speeds)),
                "straightness": round_num(median_or_zero(hid_straightness)),
                "turnJitter": round_num(median_or_zero(hid_turn)),
                "pauses": round_num(median_or_zero(hid_pauses)),
                "pointCount": round_num(median_or_zero(hid_points)),
            },
        },
        "divergence": divergence,
        "behaviorBlend": build_behavior_blend(records),
        "replay": replay,
        "tuning": tuning,
        "quality": quality,
        "profilePatchProposal": build_profile_patch_proposal(key, records, tuning, quality),
    }


def build_overall_summary(groups):
    if not groups:
        return {
            "recommendedProfile": None,
            "recommendedAdjustments": [],
        }
    primary = groups[0]
    return {
        "recommendedProfile": primary["tuning"].get("profile"),
        "recommendedAdjustments": primary["tuning"].get("adjustments", []),
        "primaryInstruction": primary["instructionKey"],
        "replay": primary.get("replay"),
    }


def build_tuning(records, divergence):
    user_speed = median_or_zero(collect_metric(records, "comparison.user.avgSpeedPxS")) or 320
    user_points = median_or_zero(collect_metric(records, "comparison.user.pointCount")) or 12
    user_pauses = median_or_zero(collect_metric(records, "comparison.user.pauses")) or 0
    user_turn = median_or_zero(collect_metric(records, "comparison.user.turnJitter")) or 0.12
    user_straightness = median_or_zero(collect_metric(records, "comparison.user.straightness")) or 0.8

    speed_center = clamp(user_speed, 100, 1000)
    speed_low = clamp(speed_center * 0.78, 100, 1000)
    speed_high = clamp(speed_center * 1.12, 100, 1000)
    pause_bias = clamp(user_pauses / 6.0, 0, 1)
    turn_bias = clamp(user_turn / 0.6, 0, 1)
    straight_bias = clamp(1 - user_straightness, 0, 1)

    replay = build_replay_summary(records)
    profile = {
        "moveSpeedPxS": {"min": round_num(speed_low), "max": round_num(speed_high)},
        "pointCount": {
            "min": int(max(4, round(user_points * 0.72))),
            "max": int(min(80, round(user_points * 1.18 + 2))),
        },
        "hesitationProbability": round_num(clamp(0.08 + pause_bias * 0.34, 0.05, 0.6)),
        "hesitationMs": {
            "min": int(36 + pause_bias * 48),
            "max": int(84 + pause_bias * 140),
        },
        "settleMs": {
            "min": int(24 + pause_bias * 30),
            "max": int(52 + pause_bias * 84),
        },
        "wind": round_num(clamp(2.2 + straight_bias * 4.5 + turn_bias * 1.8, 1.8, 9.2)),
        "jitter": round_num(clamp(0.05 + turn_bias * 0.42, 0.03, 0.5)),
        "controlSpread": round_num(clamp(16 + straight_bias * 44 + turn_bias * 18, 12, 120)),
        "detourProbability": round_num(clamp(0.04 + straight_bias * 0.32 + pause_bias * 0.18, 0.04, 0.7)),
        "targetSpreadPx": round_num(clamp(4 + straight_bias * 10 + turn_bias * 8, 3, 24)),
        "behaviorBlend": build_behavior_blend(records),
    }
    if replay["available"]:
        profile["preferredPathSkeleton"] = replay["preferredFingerprint"].get("pathSkeleton", [])
        profile["preferredRhythm"] = replay["preferredFingerprint"].get("rhythm", {})

    adjustments = []
    if divergence["speedRatio"] > 1.15:
        adjustments.append("HID 偏快，收窄并下调 moveSpeedPxS 区间。")
    elif divergence["speedRatio"] < 0.82:
        adjustments.append("HID 偏慢，适度提高 moveSpeedPxS 上限。")
    if divergence["straightnessGap"] > 0.05:
        adjustments.append("HID 轨迹过直，增加 wind / jitter / controlSpread / detourProbability。")
    if divergence["turnJitterGap"] < -0.05:
        adjustments.append("HID 转向变化偏少，提升局部抖动与路径弯曲度。")
    if divergence["pauseGap"] < -0.4:
        adjustments.append("HID 停顿过少，增加 hesitationProbability 与 settleMs。")
    if divergence["pointCountGap"] < -2:
        adjustments.append("HID 轨迹点过稀，适度提高 pointCount 范围。")
    if replay["available"] and replay["qualityMedian"] < 0.55:
        adjustments.append("compact trace 质量偏低，继续采集路径骨架、分段耗时、点击间隔和停顿片段。")

    return {
        "profile": profile,
        "adjustments": adjustments or ["当前长期统计已经接近，可继续累积样本再调。"],
    }


def build_profile_patch_proposal(instruction_key, records, tuning, quality):
    host = first_nonempty(record_value(record, "host") for record in records)
    element_sig = first_nonempty(record_value(record, "elementSig", "element_sig", "context.element.sig") for record in records)
    task_id = first_nonempty(record_value(record, "taskId", "task_id", "context.taskId") for record in records)
    action_type = first_nonempty(record_value(record, "actionType", "action_type") for record in records) or infer_action_type(instruction_key)
    profile = dict(tuning.get("profile") or {})
    motion_profile = {key: value for key, value in profile.items() if key not in {"preferredPathSkeleton", "preferredRhythm"}}
    sample_size = len(records)
    confidence = quality.get("confidence") or 0
    missing = [
        name
        for name, value in {
            "host": host,
            "elementSig": element_sig,
            "actionType": action_type,
        }.items()
        if not value
    ]
    params = {
        "version": 2,
        "strategy": "analysis-patch",
        "actionType": action_type or "move",
        "sampleSize": sample_size,
        "motion": motion_profile,
    }
    proposal = {
        "version": 1,
        "applicable": not missing,
        "reason": None if not missing else f"missing required target fields: {', '.join(missing)}",
        "instructionKey": instruction_key,
        "confidence": confidence,
        "sampleSize": sample_size,
        "method": "profiles.apply",
        "params": {
            "host": host,
            "elementSig": element_sig,
            "taskId": task_id,
            "actionType": action_type,
            "sampleSize": sample_size,
            "confidence": confidence,
            "params": params,
        },
    }
    return proposal


def record_value(record, *paths):
    for path in paths:
        value = nested_get(record, path)
        if isinstance(value, str) and value:
            return value
    return None


def first_nonempty(values):
    for value in values:
        if value:
            return value
    return None


def infer_action_type(instruction_key):
    if not instruction_key:
        return None
    tail = instruction_key.split(":")[-1]
    if tail in {"move", "click", "drag", "scroll", "type", "key"}:
        return "type" if tail == "key" else tail
    return None


def build_replay_summary(records):
    fingerprints = []
    for record in records:
        fingerprint = (
            record.get("replayFingerprint")
            or record.get("compactTrace")
            or ((record.get("analysis") or {}).get("replayFingerprint"))
            or ((record.get("daemonLearning") or {}).get("replayFingerprint"))
        )
        if isinstance(fingerprint, dict):
            fingerprints.append(normalize_replay_fingerprint(fingerprint))

    if not fingerprints:
        return {
            "available": False,
            "fingerprints": 0,
            "qualityMedian": 0,
            "preferredFingerprint": None,
            "recommendations": ["未发现 replayFingerprint/compactTrace；当前仍只能做摘要级调参。"],
        }

    def quality(item):
        return number_or_zero(item.get("quality") or item.get("confidence"))

    preferred = sorted(fingerprints, key=quality, reverse=True)[0]
    skeleton_counts = [
        len(item.get("pathSkeleton") or [])
        for item in fingerprints
    ]
    segment_counts = [
        len((item.get("rhythm") or {}).get("segmentMs") or [])
        for item in fingerprints
    ]
    recommendations = []
    if median_or_zero(skeleton_counts) < 4:
        recommendations.append("路径骨架点偏少，至少保留 8-16 个控制点以支持节奏重建。")
    if median_or_zero(segment_counts) < 3:
        recommendations.append("分段耗时偏少，无法可靠重放加速/巡航/减速节奏。")
    if not recommendations:
        recommendations.append("compact trace 已可用于 replay-aware 调参，优先复用高质量指纹并按分布采样。")

    return {
        "available": True,
        "fingerprints": len(fingerprints),
        "qualityMedian": round_num(median_or_zero([quality(item) for item in fingerprints])),
        "pathSkeletonPointMedian": round_num(median_or_zero(skeleton_counts)),
        "segmentCountMedian": round_num(median_or_zero(segment_counts)),
        "preferredFingerprint": preferred,
        "recommendations": recommendations,
    }


RHYTHM_FIELDS = (
    "segmentMs",
    "hesitationMs",
    "clickHoldMs",
    "interClickMs",
    "dwellMs",
    "interKeyMs",
)


def normalize_replay_fingerprint(fingerprint):
    normalized = dict(fingerprint)
    normalized["pathSkeleton"] = normalize_points(
        fingerprint.get("pathSkeleton")
        or fingerprint.get("path_skeleton")
        or fingerprint.get("skeleton")
        or []
    )
    normalized["rhythm"] = normalize_rhythm(fingerprint)
    if "quality" not in normalized and "confidence" in normalized:
        normalized["quality"] = number_or_zero(normalized["confidence"])
    return normalized


def normalize_rhythm(fingerprint):
    rhythm = fingerprint.get("rhythm") if isinstance(fingerprint.get("rhythm"), dict) else {}
    normalized = {}
    for field in RHYTHM_FIELDS:
        value = rhythm.get(field) or rhythm.get(to_snake_case(field)) or fingerprint.get(field) or fingerprint.get(to_snake_case(field))
        if isinstance(value, list):
            normalized[field] = [round_num(item) for item in value if isinstance(item, (int, float))]
    duration = rhythm.get("durationMs") or rhythm.get("duration_ms") or fingerprint.get("durationMs") or fingerprint.get("duration_ms")
    if isinstance(duration, (int, float)):
        normalized["durationMs"] = round_num(duration)
    return normalized


def normalize_points(points):
    normalized = []
    if not isinstance(points, list):
        return normalized
    for point in points:
        if not isinstance(point, dict):
            continue
        x = point.get("x")
        y = point.get("y")
        if isinstance(x, (int, float)) and isinstance(y, (int, float)):
            normalized.append({"x": round_num(x), "y": round_num(y)})
    return normalized


def to_snake_case(value):
    result = []
    for index, char in enumerate(value):
        if char.isupper() and index > 0:
            result.append("_")
        result.append(char.lower())
    return "".join(result)


def build_behavior_blend(records):
    counts = {"idle": 0, "normal": 0, "flow": 0, "lowEfficiency": 0}
    for record in records:
        profile = ((record.get("analysis") or {}).get("behaviorBlend")) or ((record.get("daemonLearning") or {}).get("behaviorBlend"))
        if isinstance(profile, dict):
            for key in counts:
                counts[key] += float(profile.get(key, 0) or 0)
            continue
        user_speed = nested_get(record, "comparison.user.avgSpeedPxS") or 0
        user_pauses = nested_get(record, "comparison.user.pauses") or 0
        if user_speed >= 650 and user_pauses == 0:
            counts["flow"] += 1
        elif user_speed <= 180 and user_pauses >= 1:
            counts["idle"] += 1
        elif user_pauses >= 2:
            counts["lowEfficiency"] += 1
        else:
            counts["normal"] += 1
    total = sum(counts.values()) or 1
    return {key: round_num(value / total) for key, value in counts.items()}


def improvement_signal(records):
    if len(records) < 4:
        return None
    deltas = []
    for record in records:
        comparison = record.get("comparison") or {}
        delta = comparison.get("delta") or {}
        score = abs(delta.get("avgSpeedPxS", 0)) + abs(delta.get("straightness", 0)) * 220 + abs(delta.get("turnJitter", 0)) * 120
        deltas.append(score)
    early = sum(deltas[: max(1, len(deltas) // 3)]) / max(1, len(deltas[: max(1, len(deltas) // 3)]))
    late = sum(deltas[-max(1, len(deltas) // 3):]) / max(1, len(deltas[-max(1, len(deltas) // 3):]))
    return round_num(late < early)


def collect_metric(records, dotted_path):
    values = []
    for record in records:
        value = nested_get(record, dotted_path)
        if isinstance(value, (int, float)):
            values.append(float(value))
    return values


def nested_get(obj, dotted_path):
    current = obj
    for segment in dotted_path.split("."):
        if not isinstance(current, dict):
            return None
        current = current.get(segment)
    return current


def median_or_zero(values):
    return float(median(values)) if values else 0.0


def safe_ratio(left, right):
    if not right:
        return 0
    return left / right


def number_or_zero(value):
    if isinstance(value, (int, float)):
        return float(value)
    return 0


def clamp(value, lower, upper):
    return max(lower, min(upper, value))


def round_num(value):
    return round(float(value), 4)


def main():
    parser = argparse.ArgumentParser(description="Analyze long-term human vs HID behavior divergence.")
    parser.add_argument("--history", type=Path, default=DEFAULT_HISTORY_PATH, help="Path to compact history JSONL.")
    parser.add_argument("--host")
    parser.add_argument("--instruction-key")
    parser.add_argument("--pretty", action="store_true")
    args = parser.parse_args()

    report = analyze_history(load_history(args.history), host=args.host, instruction_key=args.instruction_key)
    if args.pretty:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print(json.dumps(report, ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    main()
