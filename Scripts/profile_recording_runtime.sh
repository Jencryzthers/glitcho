#!/usr/bin/env bash
set -euo pipefail

DURATION_SECONDS=180
INTERVAL_SECONDS=2
APP_NAME="Glitcho"
APP_PID=""
OUT_DIR="Build/perf"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Capture recorder-related runtime metrics (CPU/RAM/process counts) for baseline/after comparisons.

Options:
  --duration <seconds>   Total capture duration (default: ${DURATION_SECONDS})
  --interval <seconds>   Sampling interval (default: ${INTERVAL_SECONDS})
  --app-name <name>      Main app process name to track (default: ${APP_NAME})
  --app-pid <pid>        Track a specific app PID instead of resolving by name
  --out-dir <path>       Output directory (default: ${OUT_DIR})
  --help                 Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration)
      DURATION_SECONDS="$2"
      shift 2
      ;;
    --interval)
      INTERVAL_SECONDS="$2"
      shift 2
      ;;
    --app-name)
      APP_NAME="$2"
      shift 2
      ;;
    --app-pid)
      APP_PID="$2"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! [[ "$DURATION_SECONDS" =~ ^[0-9]+$ ]] || (( DURATION_SECONDS <= 0 )); then
  echo "--duration must be a positive integer" >&2
  exit 1
fi

if ! [[ "$INTERVAL_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "--interval must be a positive number" >&2
  exit 1
fi

if [[ -n "$APP_PID" ]] && ! [[ "$APP_PID" =~ ^[0-9]+$ ]]; then
  echo "--app-pid must be numeric" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

RUN_TS="$(date +%Y%m%d_%H%M%S)"
CSV_PATH="$OUT_DIR/recording_profile_${RUN_TS}.csv"
SUMMARY_PATH="$OUT_DIR/recording_profile_${RUN_TS}.summary.txt"

echo "timestamp,app_pid,app_rss_mb,app_cpu_pct,agent_count,agent_rss_mb,agent_cpu_pct,streamlink_count,streamlink_rss_mb,streamlink_cpu_pct,ffmpeg_count,ffmpeg_rss_mb,ffmpeg_cpu_pct,total_capture_processes" > "$CSV_PATH"

aggregate_for_pids() {
  local pids="$1"
  if [[ -z "${pids//[[:space:]]/}" ]]; then
    printf "0,0.00,0.00"
    return
  fi

  local pid_csv
  pid_csv="$(echo "$pids" | tr '\n' ',' | sed 's/,$//')"

  ps -o rss= -o %cpu= -p "$pid_csv" 2>/dev/null | awk '
    { rss += $1; cpu += $2; count += 1 }
    END {
      if (count == 0) {
        printf "0,0.00,0.00"
      } else {
        printf "%d,%.2f,%.2f", count, rss / 1024, cpu
      }
    }
  '
}

capture_group() {
  local pattern="$1"
  local pids
  pids="$(pgrep -f "$pattern" || true)"
  aggregate_for_pids "$pids"
}

resolve_app_pid() {
  if [[ -n "$APP_PID" ]]; then
    if kill -0 "$APP_PID" 2>/dev/null; then
      echo "$APP_PID"
    fi
    return
  fi

  pgrep -x "$APP_NAME" | head -n 1 || true
}

read_app_metrics() {
  local pid="$1"
  if [[ -z "$pid" ]]; then
    printf "0.00,0.00"
    return
  fi

  ps -o rss= -o %cpu= -p "$pid" 2>/dev/null | awk '
    NR == 1 {
      printf "%.2f,%.2f", $1 / 1024, $2
      found = 1
    }
    END {
      if (!found) {
        printf "0.00,0.00"
      }
    }
  '
}

echo "Capturing recording runtime metrics for ${DURATION_SECONDS}s every ${INTERVAL_SECONDS}s..."
START_EPOCH="$(date +%s)"
END_EPOCH=$(( START_EPOCH + DURATION_SECONDS ))

while (( $(date +%s) < END_EPOCH )); do
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  pid="$(resolve_app_pid)"

  app_metrics="$(read_app_metrics "$pid")"
  app_rss_mb="${app_metrics%%,*}"
  app_cpu_pct="${app_metrics##*,}"

  agent_metrics="$(capture_group "[G]litchoRecorderAgent")"
  streamlink_metrics="$(capture_group "[s]treamlink")"
  ffmpeg_metrics="$(capture_group "[f]fmpeg")"

  agent_count="${agent_metrics%%,*}"
  agent_rest="${agent_metrics#*,}"
  agent_rss_mb="${agent_rest%%,*}"
  agent_cpu_pct="${agent_rest##*,}"

  streamlink_count="${streamlink_metrics%%,*}"
  streamlink_rest="${streamlink_metrics#*,}"
  streamlink_rss_mb="${streamlink_rest%%,*}"
  streamlink_cpu_pct="${streamlink_rest##*,}"

  ffmpeg_count="${ffmpeg_metrics%%,*}"
  ffmpeg_rest="${ffmpeg_metrics#*,}"
  ffmpeg_rss_mb="${ffmpeg_rest%%,*}"
  ffmpeg_cpu_pct="${ffmpeg_rest##*,}"

  total_capture_processes=$(( agent_count + streamlink_count + ffmpeg_count ))

  echo "$ts,${pid:-},$app_rss_mb,$app_cpu_pct,$agent_count,$agent_rss_mb,$agent_cpu_pct,$streamlink_count,$streamlink_rss_mb,$streamlink_cpu_pct,$ffmpeg_count,$ffmpeg_rss_mb,$ffmpeg_cpu_pct,$total_capture_processes" >> "$CSV_PATH"

  sleep "$INTERVAL_SECONDS"
done

awk -F',' '
  NR == 1 { next }
  {
    samples += 1
    app_rss_sum += $3
    app_cpu_sum += $4

    if ($3 > app_rss_max) app_rss_max = $3
    if ($4 > app_cpu_max) app_cpu_max = $4

    if ($5 > agent_count_max) agent_count_max = $5
    if ($8 > stream_count_max) stream_count_max = $8
    if ($11 > ffmpeg_count_max) ffmpeg_count_max = $11
    if ($14 > capture_count_max) capture_count_max = $14

    if ($9 > stream_rss_max) stream_rss_max = $9
    if ($12 > ffmpeg_rss_max) ffmpeg_rss_max = $12
  }
  END {
    if (samples == 0) {
      print "No samples captured.";
      exit 0;
    }

    printf "samples=%d\n", samples;
    printf "app_rss_avg_mb=%.2f\n", app_rss_sum / samples;
    printf "app_rss_peak_mb=%.2f\n", app_rss_max;
    printf "app_cpu_avg_pct=%.2f\n", app_cpu_sum / samples;
    printf "app_cpu_peak_pct=%.2f\n", app_cpu_max;
    printf "agent_count_peak=%d\n", agent_count_max;
    printf "streamlink_count_peak=%d\n", stream_count_max;
    printf "ffmpeg_count_peak=%d\n", ffmpeg_count_max;
    printf "capture_process_count_peak=%d\n", capture_count_max;
    printf "streamlink_rss_peak_mb=%.2f\n", stream_rss_max;
    printf "ffmpeg_rss_peak_mb=%.2f\n", ffmpeg_rss_max;
  }
' "$CSV_PATH" > "$SUMMARY_PATH"

echo "CSV: $CSV_PATH"
echo "Summary: $SUMMARY_PATH"
