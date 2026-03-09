# Recording Runtime Profiling (CPU / RAM / Process Counts)

Use `Scripts/profile_recording_runtime.sh` to collect comparable baseline and after-change runtime metrics for recording workloads.

## Script

```bash
./Scripts/profile_recording_runtime.sh --help
```

Key options:
- `--duration <seconds>` (default `180`)
- `--interval <seconds>` (default `2`)
- `--app-name <name>` (default `Glitcho`)
- `--app-pid <pid>`
- `--out-dir <path>` (default `Build/perf`)

## Metrics Captured

Per sample:
- App PID, RSS (MB), CPU %
- `GlitchoRecorderAgent` process count, RSS (MB), CPU %
- `streamlink` process count, RSS (MB), CPU %
- `ffmpeg` process count, RSS (MB), CPU %
- Combined capture process count

Summary output includes:
- `app_rss_avg_mb`, `app_rss_peak_mb`
- `app_cpu_avg_pct`, `app_cpu_peak_pct`
- `agent_count_peak`
- `streamlink_count_peak`
- `ffmpeg_count_peak`
- `capture_process_count_peak`

## Baseline Run

1. Launch Glitcho.
2. Reproduce a representative recording session (normal + stress scenario).
3. Capture:

```bash
./Scripts/profile_recording_runtime.sh \
  --duration 300 \
  --interval 2 \
  --out-dir Build/perf/baseline
```

Artifacts:
- `Build/perf/baseline/recording_profile_<timestamp>.csv`
- `Build/perf/baseline/recording_profile_<timestamp>.summary.txt`

## After-Change Run

Repeat same scenario and same capture parameters:

```bash
./Scripts/profile_recording_runtime.sh \
  --duration 300 \
  --interval 2 \
  --out-dir Build/perf/after
```

## Compare

Compare baseline vs after summary values:
- `app_rss_peak_mb`
- `app_cpu_peak_pct`
- `capture_process_count_peak`
- `streamlink_count_peak`
- `ffmpeg_count_peak`

Healthy improvements should show:
- Stable or reduced process count peaks
- No monotonic runaway process growth
- Lower or more stable app RSS during long capture windows

## Optional Fixed PID Mode

```bash
./Scripts/profile_recording_runtime.sh --app-pid <PID> --duration 180
```

## PR Evidence Template

```text
Workload:
Baseline summary:
- app_rss_peak_mb=
- app_cpu_peak_pct=
- capture_process_count_peak=
- streamlink_count_peak=
- ffmpeg_count_peak=

After summary:
- app_rss_peak_mb=
- app_cpu_peak_pct=
- capture_process_count_peak=
- streamlink_count_peak=
- ffmpeg_count_peak=

Delta:
- ...
```
