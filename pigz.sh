#!/usr/bin/env bash
set -Eeuo pipefail

 
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  sed -n '1,95p' "$0"
  exit 0
fi


MODE="${MODE:-full}"                         # test or full
ROOT="${ROOT:-$HOME/pigz_experiment_complete}"
RESET_ALL="${RESET_ALL:-0}"                 # 1 = delete entire experiment folder
RESET_RESULTS="${RESET_RESULTS:-0}"         # 1 = clear results/logs/callgrind only
RESUME="${RESUME:-1}"                       # 1 = skip completed normal/callgrind rows
REPEATS="${REPEATS:-3}"                     # normal monitored repeats
CALLGRIND_REPEATS="${CALLGRIND_REPEATS:-1}" # usually 1 because Callgrind is heavy
CALLGRIND_SCOPE="${CALLGRIND_SCOPE:-all}"   # all, small, none
CALLGRIND_TIMEOUT="${CALLGRIND_TIMEOUT:-0}" # example: 12h, 24h, or 0 for no timeout
PIGZ_CFLAGS="${PIGZ_CFLAGS:--O2 -g -Wall}"
ONLY_FILES="${ONLY_FILES:-}"                # example: ONLY_FILES="5GB"
ONLY_THREADS="${ONLY_THREADS:-}"            # example: ONLY_THREADS="8 16"

if [[ "$MODE" != "test" && "$MODE" != "full" ]]; then
  echo "ERROR: MODE must be test or full"
  exit 1
fi
if [[ "$CALLGRIND_SCOPE" != "all" && "$CALLGRIND_SCOPE" != "small" && "$CALLGRIND_SCOPE" != "none" ]]; then
  echo "ERROR: CALLGRIND_SCOPE must be all, small, or none"
  exit 1
fi

if [[ "$RESET_ALL" == "1" ]]; then
  echo "Deleting entire experiment folder: $ROOT"
  rm -rf "$ROOT"
fi

SRC="$ROOT/src"
DATA="$ROOT/data"
RESULTS="$ROOT/results"
LOGS="$ROOT/logs"
CALLGRIND="$ROOT/callgrind"
SYSTEM="$ROOT/system"
PLOTS="$RESULTS/plots"
RUN_LOGS="$ROOT/run_logs"
FINAL_EVIDENCE="$ROOT/final_evidence"

mkdir -p "$SRC" "$DATA" "$RESULTS" "$LOGS" "$CALLGRIND" "$SYSTEM" "$PLOTS" "$RUN_LOGS" "$FINAL_EVIDENCE"

RUN_LOG="$RUN_LOGS/run_${MODE}_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$RUN_LOG") 2>&1
trap 'echo ""; echo "ERROR: Script failed at line $LINENO"; echo "Run log: '"$RUN_LOG"'"; exit 1' ERR

print_banner() {
  echo ""
  echo "============================================================"
  echo "$1"
  echo "============================================================"
}

print_banner "PIGZ COMPLETE PERFORMANCE + HOTSPOT EXPERIMENT"
echo "Mode: $MODE"
echo "Root folder: $ROOT"
echo "Run log: $RUN_LOG"
echo "Normal repeats: $REPEATS"
echo "Callgrind repeats: $CALLGRIND_REPEATS"
echo "Callgrind scope: $CALLGRIND_SCOPE"
echo "Callgrind timeout: $CALLGRIND_TIMEOUT"
echo "Resume completed rows: $RESUME"
echo "Pigz CFLAGS: $PIGZ_CFLAGS"
echo "Started at: $(date)"

if [[ "$RESET_RESULTS" == "1" ]]; then
  print_banner "RESET: Clearing previous results, logs, Callgrind outputs and evidence"
  rm -rf "$RESULTS" "$LOGS" "$CALLGRIND" "$FINAL_EVIDENCE"
  mkdir -p "$RESULTS" "$LOGS" "$CALLGRIND" "$PLOTS" "$FINAL_EVIDENCE"
fi


bytes_for_label() {
  case "$1" in
    "1MB") echo 1000000 ;;
    "10MB") echo 10000000 ;;
    "100MB") echo 100000000 ;;
    "1GB") echo 1000000000 ;;
    "5GB") echo 5000000000 ;;
    *) echo "ERROR: Unknown file label: $1" >&2; exit 1 ;;
  esac
}

human_warning_for_callgrind() {
  if [[ "$CALLGRIND_SCOPE" == "all" && "$MODE" == "full" ]]; then
    echo ""
    echo "WARNING: You selected CALLGRIND_SCOPE=all."
    echo "This will try Callgrind for 10MB, 100MB, 1GB and 5GB with all thread counts."
    echo "The 1GB and 5GB Callgrind runs can be extremely slow and produce large files."
    echo "Use Ctrl+C if it is impractical, then rerun with RESUME=1 or CALLGRIND_SCOPE=small."
    echo ""
  fi
}

safe_kill() {
  for pid in "$@"; do
    kill "$pid" 2>/dev/null || true
  done
}

parse_vmstat() {
  local file="$1"
  awk '
  $1 ~ /^[0-9]+$/ {
    seen++;
    # Skip first numeric line because vmstat first line is average since boot.
    if (seen > 1) {
      n++;
      free += $4; bi += $9; bo += $10;
      us += $13; sy += $14; id += $15; wa += $16;
    }
  }
  END {
    if (n > 0) {
      printf "%.2f,%.2f,%.2f,%.2f,%.0f,%.2f,%.2f", us/n, sy/n, id/n, wa/n, free/n, bi/n, bo/n;
    } else {
      printf ",,,,,,";
    }
  }' "$file"
}

normal_row_exists() {
  local csv="$1" mode="$2" file_label="$3" threads="$4" repeat="$5"
  [[ -f "$csv" ]] || return 1
  awk -F, -v m="$mode" -v f="$file_label" -v t="$threads" -v r="$repeat" \
    'NR>1 && $2==m && $3==f && $4==t && $5==r {found=1} END {exit !found}' "$csv"
}

callgrind_row_exists() {
  local csv="$1" mode="$2" file_label="$3" threads="$4" repeat="$5"
  [[ -f "$csv" ]] || return 1
  awk -F, -v m="$mode" -v f="$file_label" -v t="$threads" -v r="$repeat" \
    'NR>1 && $1==m && $2==f && $3==t && $4==r {found=1} END {exit !found}' "$csv"
}

generate_file() {
  local label="$1"
  local bytes="$2"
  local path="$DATA/testfile_${label}"

  if [[ -f "$path" ]]; then
    local existing
    existing=$(stat -c%s "$path")
    if [[ "$existing" == "$bytes" ]]; then
      echo "File exists and size is correct, keeping it: $path"
      return 0
    fi
    echo "File exists but size is wrong. Regenerating: $path"
    rm -f "$path"
  fi

  echo "Generating $label file at $path"
  echo "Target bytes: $bytes"
  set +o pipefail
  base64 /dev/urandom | head -c "$bytes" > "$path"
  set -o pipefail

  local actual
  actual=$(stat -c%s "$path")
  if [[ "$actual" != "$bytes" ]]; then
    echo "ERROR: Generated file size mismatch for $label. Expected=$bytes Actual=$actual"
    exit 1
  fi
  echo "Generated successfully: $path"
}

ensure_packages() {
  print_banner "STEP 1: Checking and installing required Ubuntu packages"

  local required_packages=(
    build-essential git zlib1g-dev valgrind sysstat time procps coreutils
    util-linux python3 zip lsb-release python3-matplotlib python3-pandas
  )

  local missing=()
  local pkg
  for pkg in "${required_packages[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    echo "Missing packages found: ${missing[*]}"
    echo "Installing missing packages..."
    sudo apt update
    sudo DEBIAN_FRONTEND=noninteractive apt install -y "${missing[@]}"
  else
    echo "All required packages are already installed."
  fi

  if ! dpkg -s kcachegrind >/dev/null 2>&1; then
    echo "Optional kcachegrind is missing. Trying to install it for GUI hotspot viewing..."
    sudo apt update || true
    sudo DEBIAN_FRONTEND=noninteractive apt install -y kcachegrind || \
      echo "WARNING: kcachegrind install failed. Text Callgrind summaries will still be generated."
  else
    echo "Optional kcachegrind is already installed."
  fi

  echo ""
  echo "Tool versions:"
  gcc --version | head -n 1 || true
  make --version | head -n 1 || true
  valgrind --version || true
  vmstat --version || true
  pidstat -V || true
  iostat -V || true
  python3 --version || true
}


ensure_packages
human_warning_for_callgrind


print_banner "STEP 2: Saving system information"
{
  echo "===== DATE ====="; date
  echo ""; echo "===== OS ====="; lsb_release -a 2>/dev/null || cat /etc/os-release
  echo ""; echo "===== KERNEL ====="; uname -a
  echo ""; echo "===== CPU ====="; lscpu
  echo ""; echo "===== MEMORY ====="; free -h
  echo ""; echo "===== DISK ====="; df -h
  echo ""; echo "===== TOOLS ====="
  gcc --version | head -n 1 || true
  make --version | head -n 1 || true
  valgrind --version || true
  vmstat --version || true
  pidstat -V || true
  iostat -V || true
  python3 --version || true
} | tee "$SYSTEM/system_info.txt"


print_banner "STEP 3: Downloading and compiling Pigz with debug symbols"
cd "$SRC"

if [[ ! -d "$SRC/pigz/.git" ]]; then
  echo "Pigz source not found. Cloning official Pigz repository..."
  git clone https://github.com/madler/pigz.git
else
  echo "Pigz repository already exists. Pulling latest changes if possible..."
  git -C "$SRC/pigz" pull || true
fi

cd "$SRC/pigz"
echo "Pigz git commit:"
git rev-parse HEAD | tee "$SYSTEM/pigz_git_commit.txt"

make clean || true
make CFLAGS="$PIGZ_CFLAGS" -j"$(nproc)"
cp "$SRC/pigz/pigz" "$ROOT/pigz_debug"

"$ROOT/pigz_debug" --version || true
file "$ROOT/pigz_debug" | tee "$SYSTEM/pigz_binary_info.txt"

if ! file "$ROOT/pigz_debug" | grep -qi "debug_info\|not stripped"; then
  echo "WARNING: file command did not clearly confirm debug symbols. Check pigz_binary_info.txt."
fi

print_banner "STEP 4: Preparing experiment matrix"

if [[ "$MODE" == "test" ]]; then
  FILES=("1MB" "10MB")
  THREADS=(1 2)
else
  FILES=("10MB" "100MB" "1GB" "5GB")
  THREADS=(1 2 4 8 16)
fi

if [[ "$CALLGRIND_SCOPE" == "none" ]]; then
  CALLGRIND_FILES=()
  CALLGRIND_THREADS=()
elif [[ "$CALLGRIND_SCOPE" == "small" ]]; then
  if [[ "$MODE" == "test" ]]; then
    CALLGRIND_FILES=("1MB")
    CALLGRIND_THREADS=(1)
  else
    CALLGRIND_FILES=("10MB" "100MB")
    CALLGRIND_THREADS=(1 2 4 8 16)
  fi
else
  CALLGRIND_FILES=("${FILES[@]}")
  CALLGRIND_THREADS=("${THREADS[@]}")
fi

if [[ -n "$ONLY_FILES" ]]; then
  read -r -a FILES <<< "$ONLY_FILES"
  if [[ "$CALLGRIND_SCOPE" != "none" ]]; then
    CALLGRIND_FILES=("${FILES[@]}")
  fi
fi

if [[ -n "$ONLY_THREADS" ]]; then
  read -r -a THREADS <<< "$ONLY_THREADS"
  if [[ "$CALLGRIND_SCOPE" != "none" ]]; then
    CALLGRIND_THREADS=("${THREADS[@]}")
  fi
fi

echo "Normal files: ${FILES[*]}"
echo "Normal threads: ${THREADS[*]}"
echo "Callgrind files: ${CALLGRIND_FILES[*]:-none}"
echo "Callgrind threads: ${CALLGRIND_THREADS[*]:-none}"


print_banner "STEP 5: Generating test files"
for F in "${FILES[@]}"; do
  BYTES=$(bytes_for_label "$F")
  generate_file "$F" "$BYTES"
done
ls -lh "$DATA"


print_banner "STEP 6: Running normal monitored Pigz experiment for Task 1"
PIGZ="$ROOT/pigz_debug"
RESULT_CSV="$RESULTS/normal_results.csv"

if [[ ! -f "$RESULT_CSV" ]]; then
  echo "timestamp,mode,file_label,threads,repeat,input_bytes,output_bytes,compression_ratio_percent,elapsed_seconds,user_seconds,system_seconds,max_rss_kb,exit_status,vmstat_avg_user_pct,vmstat_avg_system_pct,vmstat_avg_idle_pct,vmstat_avg_iowait_pct,vmstat_avg_free_kb,vmstat_avg_blocks_in,vmstat_avg_blocks_out,command" > "$RESULT_CSV"
fi

for FILE_LABEL in "${FILES[@]}"; do
  INPUT="$DATA/testfile_${FILE_LABEL}"
  INPUT_BYTES=$(stat -c%s "$INPUT")

  for T in "${THREADS[@]}"; do
    for R in $(seq 1 "$REPEATS"); do
      if [[ "$RESUME" == "1" ]] && normal_row_exists "$RESULT_CSV" "$MODE" "$FILE_LABEL" "$T" "$R"; then
        echo "Skipping completed normal run: mode=$MODE file=$FILE_LABEL threads=$T repeat=$R"
        continue
      fi

      echo ""
      echo "------------------------------------------------------------"
      echo "Normal Pigz run: mode=$MODE file=$FILE_LABEL threads=$T repeat=$R"
      echo "------------------------------------------------------------"

      OUT="$DATA/testfile_${FILE_LABEL}.gz"
      TIME_TMP="$LOGS/time_${MODE}_${FILE_LABEL}_p${T}_r${R}.csv"
      VMSTAT_LOG="$LOGS/vmstat_${MODE}_${FILE_LABEL}_p${T}_r${R}.log"
      IOSTAT_LOG="$LOGS/iostat_${MODE}_${FILE_LABEL}_p${T}_r${R}.log"
      PIDSTAT_LOG="$LOGS/pidstat_${MODE}_${FILE_LABEL}_p${T}_r${R}.log"

      rm -f "$OUT"
      vmstat 1 > "$VMSTAT_LOG" & VMSTAT_PID=$!
      iostat -x 1 > "$IOSTAT_LOG" & IOSTAT_PID=$!
      pidstat -C pigz_debug -urd 1 > "$PIDSTAT_LOG" & PIDSTAT_PID=$!

      /usr/bin/time -f "%e,%U,%S,%M,%x" -o "$TIME_TMP" \
        "$PIGZ" -k -f -p "$T" "$INPUT"

      safe_kill "$VMSTAT_PID" "$IOSTAT_PID" "$PIDSTAT_PID"
      sleep 1

      if [[ ! -f "$OUT" ]]; then
        echo "ERROR: Output file not created: $OUT"
        exit 1
      fi

      OUTPUT_BYTES=$(stat -c%s "$OUT")
      RATIO=$(awk -v out="$OUTPUT_BYTES" -v inp="$INPUT_BYTES" 'BEGIN { printf "%.2f", (out/inp)*100 }')
      TIME_VALUES=$(cat "$TIME_TMP")
      IFS=',' read -r ELAPSED USER_TIME SYSTEM_TIME MAX_RSS EXIT_STATUS <<< "$TIME_VALUES"
      VMSTAT_VALUES=$(parse_vmstat "$VMSTAT_LOG")
      COMMAND="./pigz -k -f -p $T testfile_${FILE_LABEL}"

      echo "$(date '+%Y-%m-%d %H:%M:%S'),$MODE,$FILE_LABEL,$T,$R,$INPUT_BYTES,$OUTPUT_BYTES,$RATIO,$ELAPSED,$USER_TIME,$SYSTEM_TIME,$MAX_RSS,$EXIT_STATUS,$VMSTAT_VALUES,$COMMAND" >> "$RESULT_CSV"
      echo "Done: file=$FILE_LABEL threads=$T repeat=$R elapsed=${ELAPSED}s ratio=${RATIO}% maxRSS=${MAX_RSS}KB"
    done
  done
done

echo "Saved Task 1 normal results: $RESULT_CSV"

print_banner "STEP 7: Running Callgrind hotspot profiling for Task 2"
CALLGRIND_CSV="$RESULTS/callgrind_results.csv"

if [[ ! -f "$CALLGRIND_CSV" ]]; then
  echo "mode,file_label,threads,repeat,elapsed_seconds,user_seconds,system_seconds,max_rss_kb,exit_status,input_bytes,output_bytes,compression_ratio_percent,callgrind_output,self_summary_output,inclusive_summary_output,command" > "$CALLGRIND_CSV"
fi

if [[ "$CALLGRIND_SCOPE" == "none" ]]; then
  echo "Skipping Callgrind because CALLGRIND_SCOPE=none"
else
  for FILE_LABEL in "${CALLGRIND_FILES[@]}"; do
    INPUT="$DATA/testfile_${FILE_LABEL}"
    [[ -f "$INPUT" ]] || { echo "WARNING: Missing Callgrind input: $INPUT"; continue; }
    INPUT_BYTES=$(stat -c%s "$INPUT")

    for T in "${CALLGRIND_THREADS[@]}"; do
      for R in $(seq 1 "$CALLGRIND_REPEATS"); do
        if [[ "$RESUME" == "1" ]] && callgrind_row_exists "$CALLGRIND_CSV" "$MODE" "$FILE_LABEL" "$T" "$R"; then
          echo "Skipping completed Callgrind run: mode=$MODE file=$FILE_LABEL threads=$T repeat=$R"
          continue
        fi

        echo ""
        echo "------------------------------------------------------------"
        echo "Callgrind run: mode=$MODE file=$FILE_LABEL threads=$T repeat=$R"
        echo "WARNING: Larger Callgrind runs can take a very long time."
        echo "------------------------------------------------------------"

        OUT="$DATA/testfile_${FILE_LABEL}.gz"
        OUTFILE="$CALLGRIND/callgrind.out.${MODE}_${FILE_LABEL}_p${T}_r${R}"
        SELF_SUMMARY="$RESULTS/callgrind_annotate_self_${MODE}_${FILE_LABEL}_p${T}_r${R}.txt"
        INCL_SUMMARY="$RESULTS/callgrind_annotate_inclusive_${MODE}_${FILE_LABEL}_p${T}_r${R}.txt"
        TIME_TMP="$LOGS/time_callgrind_${MODE}_${FILE_LABEL}_p${T}_r${R}.csv"
        COMMAND="valgrind --tool=callgrind ./pigz -k -f -p $T testfile_${FILE_LABEL}"

        rm -f "$OUT" "$OUTFILE" "$SELF_SUMMARY" "$INCL_SUMMARY"

        if [[ "$CALLGRIND_TIMEOUT" == "0" ]]; then
          /usr/bin/time -f "%e,%U,%S,%M,%x" -o "$TIME_TMP" \
            valgrind --tool=callgrind --collect-jumps=yes --callgrind-out-file="$OUTFILE" \
            "$PIGZ" -k -f -p "$T" "$INPUT"
        else
          set +e
          /usr/bin/time -f "%e,%U,%S,%M,%x" -o "$TIME_TMP" \
            timeout "$CALLGRIND_TIMEOUT" \
            valgrind --tool=callgrind --collect-jumps=yes --callgrind-out-file="$OUTFILE" \
            "$PIGZ" -k -f -p "$T" "$INPUT"
          STATUS=$?
          set -e
          if [[ "$STATUS" != "0" ]]; then
            echo "WARNING: Callgrind run failed or timed out with status $STATUS for $FILE_LABEL p$T r$R"
          fi
        fi

        if [[ -f "$OUTFILE" ]]; then
          callgrind_annotate "$OUTFILE" > "$SELF_SUMMARY" || true
          callgrind_annotate --inclusive=yes "$OUTFILE" > "$INCL_SUMMARY" || true
        else
          echo "WARNING: No Callgrind output file generated: $OUTFILE"
        fi

        OUTPUT_BYTES=""
        RATIO=""
        if [[ -f "$OUT" ]]; then
          OUTPUT_BYTES=$(stat -c%s "$OUT")
          RATIO=$(awk -v out="$OUTPUT_BYTES" -v inp="$INPUT_BYTES" 'BEGIN { printf "%.2f", (out/inp)*100 }')
        fi

        if [[ -f "$TIME_TMP" ]]; then
          TIME_VALUES=$(cat "$TIME_TMP")
          IFS=',' read -r ELAPSED USER_TIME SYSTEM_TIME MAX_RSS EXIT_STATUS <<< "$TIME_VALUES"
        else
          ELAPSED=""; USER_TIME=""; SYSTEM_TIME=""; MAX_RSS=""; EXIT_STATUS=""
        fi

        echo "$MODE,$FILE_LABEL,$T,$R,$ELAPSED,$USER_TIME,$SYSTEM_TIME,$MAX_RSS,$EXIT_STATUS,$INPUT_BYTES,$OUTPUT_BYTES,$RATIO,$OUTFILE,$SELF_SUMMARY,$INCL_SUMMARY,$COMMAND" >> "$CALLGRIND_CSV"
        echo "Callgrind saved: $OUTFILE"
        echo "Self summary: $SELF_SUMMARY"
        echo "Inclusive summary: $INCL_SUMMARY"
      done
    done
  done
fi


print_banner "STEP 8: Generating Task 1 and Task 2 report-ready tables and plots"
python3 <<'PY'
import csv
import re
from pathlib import Path
from collections import defaultdict, Counter

root = Path.home() / "pigz_experiment_complete"
results = root / "results"
plots = results / "plots"
plots.mkdir(exist_ok=True)
normal_csv = results / "normal_results.csv"
callgrind_csv = results / "callgrind_results.csv"

file_order = ["1MB", "10MB", "100MB", "1GB", "5GB"]
thread_order = [1, 2, 4, 8, 16]

def safe_float(x):
    try: return float(x)
    except Exception: return None

def safe_int(x):
    try: return int(float(str(x).replace(',', '')))
    except Exception: return None

def avg(vals):
    vals = [v for v in vals if v is not None]
    return sum(vals) / len(vals) if vals else None

# ---------------- Task 1 normal summaries ----------------
rows = []
if normal_csv.exists():
    with normal_csv.open(newline="") as f:
        reader = csv.DictReader(f)
        for r in reader:
            r["threads"] = safe_int(r.get("threads"))
            r["repeat"] = safe_int(r.get("repeat"))
            for k in ["input_bytes", "output_bytes", "elapsed_seconds", "user_seconds", "system_seconds", "max_rss_kb", "compression_ratio_percent", "vmstat_avg_user_pct", "vmstat_avg_system_pct", "vmstat_avg_idle_pct", "vmstat_avg_iowait_pct", "vmstat_avg_free_kb", "vmstat_avg_blocks_in", "vmstat_avg_blocks_out"]:
                r[k] = safe_float(r.get(k))
            if r["threads"] is not None:
                rows.append(r)

grouped = defaultdict(list)
for r in rows:
    grouped[(r["mode"], r["file_label"], r["threads"])].append(r)

avg_rows = []
for (mode, file_label, threads), items in sorted(grouped.items(), key=lambda x: (x[0][0], file_order.index(x[0][1]) if x[0][1] in file_order else 99, x[0][2])):
    avg_rows.append({
        "mode": mode,
        "file_label": file_label,
        "threads": threads,
        "runs": len(items),
        "avg_elapsed_seconds": avg([x["elapsed_seconds"] for x in items]),
        "avg_user_seconds": avg([x["user_seconds"] for x in items]),
        "avg_system_seconds": avg([x["system_seconds"] for x in items]),
        "avg_max_rss_kb": avg([x["max_rss_kb"] for x in items]),
        "avg_compression_ratio_percent": avg([x["compression_ratio_percent"] for x in items]),
        "avg_vmstat_user_pct": avg([x["vmstat_avg_user_pct"] for x in items]),
        "avg_vmstat_system_pct": avg([x["vmstat_avg_system_pct"] for x in items]),
        "avg_vmstat_idle_pct": avg([x["vmstat_avg_idle_pct"] for x in items]),
        "avg_vmstat_iowait_pct": avg([x["vmstat_avg_iowait_pct"] for x in items]),
        "avg_vmstat_blocks_in": avg([x["vmstat_avg_blocks_in"] for x in items]),
        "avg_vmstat_blocks_out": avg([x["vmstat_avg_blocks_out"] for x in items]),
        "input_bytes": avg([x["input_bytes"] for x in items]),
        "output_bytes": avg([x["output_bytes"] for x in items]),
    })

with (results / "summary_average_by_file_thread.csv").open("w", newline="") as f:
    fieldnames = [
        "mode", "file_label", "threads", "runs", "avg_elapsed_seconds", "avg_user_seconds", "avg_system_seconds",
        "avg_max_rss_kb", "avg_compression_ratio_percent", "avg_vmstat_user_pct", "avg_vmstat_system_pct",
        "avg_vmstat_idle_pct", "avg_vmstat_iowait_pct", "avg_vmstat_blocks_in", "avg_vmstat_blocks_out"
    ]
    w = csv.DictWriter(f, fieldnames=fieldnames)
    w.writeheader()
    for r in avg_rows:
        out = {k: r.get(k) for k in fieldnames}
        for k, v in list(out.items()):
            if isinstance(v, float):
                out[k] = f"{v:.3f}" if "seconds" in k else f"{v:.2f}"
        w.writerow(out)

best = {}
for r in avg_rows:
    if r["avg_elapsed_seconds"] is None: continue
    key = (r["mode"], r["file_label"])
    if key not in best or r["avg_elapsed_seconds"] < best[key]["avg_elapsed_seconds"]:
        best[key] = r

with (results / "summary_best_thread_per_file.csv").open("w", newline="") as f:
    fieldnames = ["mode", "file_label", "best_threads", "best_avg_elapsed_seconds", "avg_compression_ratio_percent", "avg_max_rss_kb"]
    w = csv.DictWriter(f, fieldnames=fieldnames)
    w.writeheader()
    for (mode, file_label), r in sorted(best.items(), key=lambda x: (x[0][0], file_order.index(x[0][1]) if x[0][1] in file_order else 99)):
        w.writerow({
            "mode": mode,
            "file_label": file_label,
            "best_threads": r["threads"],
            "best_avg_elapsed_seconds": f"{r['avg_elapsed_seconds']:.3f}",
            "avg_compression_ratio_percent": f"{r['avg_compression_ratio_percent']:.2f}" if r['avg_compression_ratio_percent'] is not None else "",
            "avg_max_rss_kb": f"{r['avg_max_rss_kb']:.0f}" if r['avg_max_rss_kb'] is not None else "",
        })

lookup = {(r["mode"], r["file_label"], r["threads"]): r for r in avg_rows}
modes = sorted(set(r["mode"] for r in avg_rows))

def write_matrix(path, metric, fmt="{:.3f}"):
    with path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["mode", "file_size"] + [f"p{t}" for t in thread_order])
        for mode in modes:
            for file_label in file_order:
                if not any((mode, file_label, t) in lookup for t in thread_order):
                    continue
                row = [mode, file_label]
                for t in thread_order:
                    item = lookup.get((mode, file_label, t))
                    val = item.get(metric) if item else None
                    row.append(fmt.format(val) if val is not None else "")
                w.writerow(row)

write_matrix(results / "table_execution_time_seconds.csv", "avg_elapsed_seconds", "{:.3f}")
write_matrix(results / "table_memory_max_rss_kb.csv", "avg_max_rss_kb", "{:.0f}")
write_matrix(results / "table_compression_ratio_percent.csv", "avg_compression_ratio_percent", "{:.2f}")

# speedup matrix: time at p1 / time at pN
with (results / "table_speedup_vs_1thread.csv").open("w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["mode", "file_size"] + [f"p{t}" for t in thread_order])
    for mode in modes:
        for file_label in file_order:
            base = lookup.get((mode, file_label, 1), {}).get("avg_elapsed_seconds")
            if base is None: continue
            row = [mode, file_label]
            for t in thread_order:
                item = lookup.get((mode, file_label, t))
                val = item.get("avg_elapsed_seconds") if item else None
                row.append(f"{base/val:.2f}" if val else "")
            w.writerow(row)

with (results / "table_cpu_io_summary.csv").open("w", newline="") as f:
    fieldnames = ["mode", "file_label", "threads", "avg_user_pct", "avg_system_pct", "avg_idle_pct", "avg_iowait_pct", "avg_blocks_in", "avg_blocks_out"]
    w = csv.DictWriter(f, fieldnames=fieldnames)
    w.writeheader()
    for r in avg_rows:
        w.writerow({
            "mode": r["mode"], "file_label": r["file_label"], "threads": r["threads"],
            "avg_user_pct": f"{r['avg_vmstat_user_pct']:.2f}" if r['avg_vmstat_user_pct'] is not None else "",
            "avg_system_pct": f"{r['avg_vmstat_system_pct']:.2f}" if r['avg_vmstat_system_pct'] is not None else "",
            "avg_idle_pct": f"{r['avg_vmstat_idle_pct']:.2f}" if r['avg_vmstat_idle_pct'] is not None else "",
            "avg_iowait_pct": f"{r['avg_vmstat_iowait_pct']:.2f}" if r['avg_vmstat_iowait_pct'] is not None else "",
            "avg_blocks_in": f"{r['avg_vmstat_blocks_in']:.2f}" if r['avg_vmstat_blocks_in'] is not None else "",
            "avg_blocks_out": f"{r['avg_vmstat_blocks_out']:.2f}" if r['avg_vmstat_blocks_out'] is not None else "",
        })

# ---------------- Task 2 Callgrind hotspot parsing ----------------
num_line = re.compile(r"^\s*([0-9][0-9,]*)\s*(?:\([^)]*\))?\s+(.+?)\s*$")
program_total_re = re.compile(r"^\s*([0-9][0-9,]*)\s+PROGRAM TOTALS")

def clean_symbol(s):
    s = s.strip()
    s = re.sub(r"\s+", " ", s)
    s = s.replace("'", "")
    # Keep useful final function-like part when possible.
    if ":" in s:
        tail = s.split(":")[-1].strip()
        if tail and tail not in ("???", "0x0"):
            return tail
    # Address-only libz lines are still useful but give them a readable label.
    m = re.search(r"(0x[0-9a-fA-F]+).*?(libz[^\s]*)", s)
    if m:
        return f"libz:{m.group(1)}"
    return s[:120]

def parse_callgrind_summary(path, mode, file_label, threads, repeat, summary_type):
    out = []
    if not path or not Path(path).exists():
        return out
    text = Path(path).read_text(errors="replace").splitlines()
    total = None
    for line in text:
        m = program_total_re.match(line)
        if m:
            total = int(m.group(1).replace(',', ''))
            break
    rank = 0
    seen_symbols = set()
    for line in text:
        if "PROGRAM TOTALS" in line or line.strip().startswith("--"):
            continue
        m = num_line.match(line)
        if not m:
            continue
        ir = int(m.group(1).replace(',', ''))
        symbol_raw = m.group(2).strip()
        if not symbol_raw or symbol_raw.startswith("*") or symbol_raw.lower().startswith("events"):
            continue
        symbol = clean_symbol(symbol_raw)
        if symbol in seen_symbols:
            continue
        seen_symbols.add(symbol)
        pct = (ir / total * 100.0) if total else None
        rank += 1
        out.append({
            "mode": mode, "file_label": file_label, "threads": threads, "repeat": repeat,
            "summary_type": summary_type, "rank": rank, "instruction_refs": ir,
            "percent_of_program": pct, "symbol": symbol, "raw_symbol": symbol_raw[:240], "summary_file": str(path)
        })
        if rank >= 30:
            break
    return out

call_rows = []
if callgrind_csv.exists():
    with callgrind_csv.open(newline="") as f:
        reader = csv.DictReader(f)
        for r in reader:
            call_rows.append(r)

hotspots = []
for r in call_rows:
    mode = r.get("mode", "")
    file_label = r.get("file_label", "")
    threads = safe_int(r.get("threads"))
    repeat = safe_int(r.get("repeat"))
    hotspots.extend(parse_callgrind_summary(r.get("self_summary_output", ""), mode, file_label, threads, repeat, "self"))
    hotspots.extend(parse_callgrind_summary(r.get("inclusive_summary_output", ""), mode, file_label, threads, repeat, "inclusive"))

for summary_type, filename in [("self", "callgrind_hotspots_self.csv"), ("inclusive", "callgrind_hotspots_inclusive.csv")]:
    with (results / filename).open("w", newline="") as f:
        fieldnames = ["mode", "file_label", "threads", "repeat", "summary_type", "rank", "instruction_refs", "percent_of_program", "symbol", "raw_symbol", "summary_file"]
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for h in hotspots:
            if h["summary_type"] != summary_type: continue
            row = dict(h)
            row["percent_of_program"] = f"{h['percent_of_program']:.2f}" if h["percent_of_program"] is not None else ""
            w.writerow(row)

# top hotspot by run
with (results / "callgrind_top_hotspot_by_run.csv").open("w", newline="") as f:
    fieldnames = ["mode", "file_label", "threads", "repeat", "summary_type", "top_symbol", "top_instruction_refs", "top_percent_of_program"]
    w = csv.DictWriter(f, fieldnames=fieldnames)
    w.writeheader()
    top_by_key = {}
    for h in hotspots:
        key = (h["mode"], h["file_label"], h["threads"], h["repeat"], h["summary_type"])
        if h["rank"] == 1:
            top_by_key[key] = h
    for key, h in sorted(top_by_key.items(), key=lambda x: (x[0][0], file_order.index(x[0][1]) if x[0][1] in file_order else 99, x[0][2] or 0, x[0][4])):
        w.writerow({
            "mode": h["mode"], "file_label": h["file_label"], "threads": h["threads"], "repeat": h["repeat"],
            "summary_type": h["summary_type"], "top_symbol": h["symbol"],
            "top_instruction_refs": h["instruction_refs"],
            "top_percent_of_program": f"{h['percent_of_program']:.2f}" if h["percent_of_program"] is not None else "",
        })

# aggregate hotspot symbols, top 20
agg = defaultdict(lambda: {"count":0, "pct_sum":0.0, "pct_n":0, "ir_sum":0})
for h in hotspots:
    if h["summary_type"] != "self":
        continue
    a = agg[h["symbol"]]
    a["count"] += 1
    a["ir_sum"] += h["instruction_refs"]
    if h["percent_of_program"] is not None:
        a["pct_sum"] += h["percent_of_program"]
        a["pct_n"] += 1

with (results / "callgrind_hotspot_symbol_summary.csv").open("w", newline="") as f:
    fieldnames = ["symbol", "appearances", "avg_self_percent", "total_instruction_refs"]
    w = csv.DictWriter(f, fieldnames=fieldnames)
    w.writeheader()
    for sym, a in sorted(agg.items(), key=lambda kv: kv[1]["ir_sum"], reverse=True)[:50]:
        w.writerow({
            "symbol": sym,
            "appearances": a["count"],
            "avg_self_percent": f"{(a['pct_sum']/a['pct_n']):.2f}" if a["pct_n"] else "",
            "total_instruction_refs": a["ir_sum"],
        })

# ---------------- Report-ready markdown ----------------
md = results / "report_ready_summary.md"
with md.open("w") as f:
    f.write("# Pigz Complete Experiment Report-Ready Summary\n\n")
    f.write("## Task 1: Best Thread Per File\n\n")
    f.write("| Mode | File | Best Threads | Avg Time (s) | Compression Ratio (%) | Max RSS (KB) |\n")
    f.write("|---|---|---:|---:|---:|---:|\n")
    for (mode, file_label), r in sorted(best.items(), key=lambda x: (x[0][0], file_order.index(x[0][1]) if x[0][1] in file_order else 99)):
        f.write(f"| {mode} | {file_label} | {r['threads']} | {r['avg_elapsed_seconds']:.3f} | {r['avg_compression_ratio_percent']:.2f} | {r['avg_max_rss_kb']:.0f} |\n")

    f.write("\n## Task 2: Hotspot Evidence\n\n")
    f.write("| File | Threads | Type | Top Hotspot | Percent of Program |\n")
    f.write("|---|---:|---|---|---:|\n")
    top_file = results / "callgrind_top_hotspot_by_run.csv"
    if top_file.exists():
        with top_file.open(newline="") as tf:
            for r in csv.DictReader(tf):
                f.write(f"| {r['file_label']} | {r['threads']} | {r['summary_type']} | {r['top_symbol']} | {r['top_percent_of_program']} |\n")

    f.write("\n## Interpretation Checklist\n\n")
    f.write("- Execution time should generally decrease as thread count increases for larger files.\n")
    f.write("- Small files may not improve as much because thread setup/coordination overhead is more visible.\n")
    f.write("- If gains flatten after 8 or 16 threads, that supports diminishing returns.\n")
    f.write("- Stable compression ratio means thread count changes speed, not output efficiency.\n")
    f.write("- Low iowait plus high user CPU suggests CPU-bound compression.\n")
    f.write("- Callgrind hotspots should mainly appear in zlib/libz deflate, checksum, and memory movement routines.\n")

# ---------------- Plots ----------------
try:
    import matplotlib.pyplot as plt

    # Task 1: all files execution time
    for mode in modes:
        mode_rows = [r for r in avg_rows if r["mode"] == mode]
        files = sorted(set(r["file_label"] for r in mode_rows), key=lambda x: file_order.index(x) if x in file_order else 99)

        plt.figure()
        for file_label in files:
            sub = sorted([r for r in mode_rows if r["file_label"] == file_label], key=lambda x: x["threads"])
            plt.plot([r["threads"] for r in sub], [r["avg_elapsed_seconds"] for r in sub], marker="o", label=file_label)
        plt.xlabel("Thread Count")
        plt.ylabel("Execution Time (seconds)")
        plt.title(f"Task 1: Execution Time vs Thread Count ({mode})")
        plt.legend()
        plt.grid(True)
        plt.savefig(plots / f"task1_execution_time_all_files_{mode}.png", dpi=200, bbox_inches="tight")
        plt.close()

        plt.figure()
        for file_label in files:
            sub = sorted([r for r in mode_rows if r["file_label"] == file_label], key=lambda x: x["threads"])
            base = next((r["avg_elapsed_seconds"] for r in sub if r["threads"] == 1), None)
            if not base: continue
            plt.plot([r["threads"] for r in sub], [base/r["avg_elapsed_seconds"] for r in sub], marker="o", label=file_label)
        plt.xlabel("Thread Count")
        plt.ylabel("Speedup vs 1 Thread")
        plt.title(f"Task 1: Speedup vs Thread Count ({mode})")
        plt.legend()
        plt.grid(True)
        plt.savefig(plots / f"task1_speedup_all_files_{mode}.png", dpi=200, bbox_inches="tight")
        plt.close()

        plt.figure()
        for file_label in files:
            sub = sorted([r for r in mode_rows if r["file_label"] == file_label], key=lambda x: x["threads"])
            plt.plot([r["threads"] for r in sub], [r["avg_max_rss_kb"]/1024 for r in sub], marker="o", label=file_label)
        plt.xlabel("Thread Count")
        plt.ylabel("Max RSS Memory (MB)")
        plt.title(f"Task 1: Memory Usage vs Thread Count ({mode})")
        plt.legend()
        plt.grid(True)
        plt.savefig(plots / f"task1_memory_usage_all_files_{mode}.png", dpi=200, bbox_inches="tight")
        plt.close()

        # CPU user vs iowait for large files only if present.
        cpu_sub = [r for r in mode_rows if r["file_label"] in ("1GB", "5GB") and r["threads"] in (1, 8, 16)]
        if cpu_sub:
            labels = [f"{r['file_label']} p{r['threads']}" for r in cpu_sub]
            x = range(len(labels))
            plt.figure()
            plt.bar([i - 0.2 for i in x], [r["avg_vmstat_user_pct"] or 0 for r in cpu_sub], width=0.4, label="User CPU %")
            plt.bar([i + 0.2 for i in x], [r["avg_vmstat_iowait_pct"] or 0 for r in cpu_sub], width=0.4, label="I/O wait %")
            plt.xticks(list(x), labels, rotation=45, ha="right")
            plt.ylabel("Percent")
            plt.title(f"Task 1: CPU User vs I/O Wait ({mode})")
            plt.legend()
            plt.tight_layout()
            plt.savefig(plots / f"task1_cpu_user_vs_iowait_{mode}.png", dpi=200, bbox_inches="tight")
            plt.close()

    # Task 2 plots based on parsed hotspots.
    self_hotspots = [h for h in hotspots if h["summary_type"] == "self" and h["rank"] <= 5]
    top_self = [h for h in hotspots if h["summary_type"] == "self" and h["rank"] == 1 and h["percent_of_program"] is not None]
    if top_self:
        plt.figure()
        for file_label in sorted(set(h["file_label"] for h in top_self), key=lambda x: file_order.index(x) if x in file_order else 99):
            sub = sorted([h for h in top_self if h["file_label"] == file_label], key=lambda x: x["threads"] or 0)
            plt.plot([h["threads"] for h in sub], [h["percent_of_program"] for h in sub], marker="o", label=file_label)
        plt.xlabel("Thread Count")
        plt.ylabel("Top Self Hotspot (% of program)")
        plt.title("Task 2: Top Self Hotspot vs Thread Count")
        plt.legend()
        plt.grid(True)
        plt.savefig(plots / "task2_top_self_hotspot_vs_threads.png", dpi=200, bbox_inches="tight")
        plt.close()

    sym_summary = []
    sym_path = results / "callgrind_hotspot_symbol_summary.csv"
    if sym_path.exists():
        with sym_path.open(newline="") as f:
            sym_summary = list(csv.DictReader(f))[:10]
    if sym_summary:
        labels = [r["symbol"][:35] for r in sym_summary]
        vals = [safe_float(r["avg_self_percent"]) or 0 for r in sym_summary]
        plt.figure()
        y = range(len(labels))
        plt.barh(list(y), vals)
        plt.yticks(list(y), labels)
        plt.xlabel("Average Self Time (% of program)")
        plt.title("Task 2: Top Hotspot Symbols")
        plt.tight_layout()
        plt.savefig(plots / "task2_top_hotspot_symbols.png", dpi=200, bbox_inches="tight")
        plt.close()

except Exception as e:
    print(f"Plot generation failed or skipped: {e}")

print("Generated report-ready files in", results)
PY


print_banner "STEP 9: Printing final table previews"
for f in \
  "$RESULTS/summary_average_by_file_thread.csv" \
  "$RESULTS/summary_best_thread_per_file.csv" \
  "$RESULTS/table_execution_time_seconds.csv" \
  "$RESULTS/table_speedup_vs_1thread.csv" \
  "$RESULTS/table_memory_max_rss_kb.csv" \
  "$RESULTS/table_compression_ratio_percent.csv" \
  "$RESULTS/table_cpu_io_summary.csv" \
  "$RESULTS/callgrind_results.csv" \
  "$RESULTS/callgrind_top_hotspot_by_run.csv" \
  "$RESULTS/callgrind_hotspot_symbol_summary.csv"; do
  if [[ -f "$f" ]]; then
    echo ""
    echo "------------------------------------------------------------"
    echo "$f"
    echo "------------------------------------------------------------"
    column -s, -t "$f" | head -n 40 || head -n 40 "$f"
  fi
done

print_banner "STEP 10: Hotspot preview"
if [[ -f "$RESULTS/callgrind_hotspots_self.csv" ]]; then
  echo "Top self hotspots:"
  column -s, -t "$RESULTS/callgrind_hotspots_self.csv" | head -n 30 || head -n 30 "$RESULTS/callgrind_hotspots_self.csv"
else
  echo "No parsed Callgrind hotspot CSV found."
fi


print_banner "STEP 11: Report-ready summary"
cat "$RESULTS/report_ready_summary.md" || true

print_banner "STEP 12: Creating final evidence zip"
cd "$ROOT"
rm -rf "$FINAL_EVIDENCE"
mkdir -p "$FINAL_EVIDENCE"
cp "$RUN_LOG" "$FINAL_EVIDENCE/" || true
cp "$SYSTEM/system_info.txt" "$FINAL_EVIDENCE/" || true
cp "$SYSTEM/pigz_git_commit.txt" "$FINAL_EVIDENCE/" || true
cp "$SYSTEM/pigz_binary_info.txt" "$FINAL_EVIDENCE/" || true
cp "$RESULTS"/*.csv "$FINAL_EVIDENCE/" 2>/dev/null || true
cp "$RESULTS"/*.md "$FINAL_EVIDENCE/" 2>/dev/null || true
cp "$RESULTS"/*.txt "$FINAL_EVIDENCE/" 2>/dev/null || true
cp -r "$PLOTS" "$FINAL_EVIDENCE/plots" 2>/dev/null || true

zip -qr "$ROOT/pigz_complete_final_evidence.zip" \
  final_evidence logs callgrind results system run_logs \
  -x "data/*"

print_banner "ALL DONE"
echo "Completed at: $(date)"
echo ""
echo "Main output log:"
echo "$RUN_LOG"
echo ""
echo "Final evidence zip:"
echo "$ROOT/pigz_complete_final_evidence.zip"
echo ""
echo "Important output folder:"
echo "$RESULTS"
echo ""
echo "Open output folder in Windows File Explorer with:"
echo "explorer.exe $ROOT"
echo "============================================================"
