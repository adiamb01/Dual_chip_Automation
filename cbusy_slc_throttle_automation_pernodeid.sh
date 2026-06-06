#!/usr/bin/env bash
set -euo pipefail

# HN-S XP/node IDs extracted from the platform CMN diagram.
# Entries marked 2xHN-S share an XP/node ID; perf bynodeid filters at this node ID.
DEFAULT_HNS_NODE_IDS="0x108 0x110 0x118 0x120 0x128 0x188 0x190 0x198 0x1a0 0x1a8 0x208 0x210 0x218 0x220 0x228 0x288 0x290 0x298 0x2a0 0x2a8 0x308 0x310 0x318 0x320 0x328 0x388 0x390 0x398 0x3a0 0x3a8 0x88 0x90 0x98 0xa0 0xa8"

usage() {
  cat <<'EOF'
Usage:
  ./cbusy_slc_throttle_automation.sh [DURATION] [INTERVAL_MS] [CPU_LIST] [CMN_SEL] [CPU_CLOCK] [CMN_CLOCK]
  ./cbusy_slc_throttle_automation.sh --parse-only OUT_DIR [CPU_CLOCK] [CMN_CLOCK]

Optional HN-S node split:
  # Uses built-in HN-S node IDs from this platform by default.
  ./cbusy_slc_throttle_automation.sh 10 500 0 both 3.0GHz 2.0GHz
  # Override if needed:
  HNS_NODE_IDS="0x88,0x90,0x98" ./cbusy_slc_throttle_automation.sh 10 500 0 both

Examples:
  ./cbusy_slc_throttle_automation.sh 10 500 0 both
  ./cbusy_slc_throttle_automation.sh --parse-only /root/cmn_results/cbusy_snapshot_nomux_YYYYmmdd_HHMMSS 3.0GHz 2.0GHz

Environment:
  OUT=/path/to/output       Override output directory for capture mode.
  HNS_NODE_IDS="..."        Optional override: comma/space-separated CMN HN-S node IDs for per-HN-S PoCQ/CBusy.
  CPU_CLOCK_HZ=3000000000  Optional clock override for L2_TQ_FULL percent normalization.
  CMN_CLOCK_HZ=2000000000  Optional clock override for PoCQ occupancy percent normalization.
  DEFAULT_HNS_NODE_IDS       Built-in list extracted from cmn_diagram.txt for this platform.

Notes:
  CPU CBusy r19c is reported separately and excluded from CBusy percentage totals.
  CPU CBusy and L2 TQ are collected with perf -A, so fresh runs include per-CPU rows.
  L2_TQ_FULL percent is computed as count / (CPU_CLOCK_HZ * interval_seconds) * 100 when CPU_CLOCK is supplied.
  PoCQ occupancy percent is computed as occupancy_count / (CMN_CLOCK_HZ * interval_seconds) * 100 when CMN_CLOCK is supplied.
EOF
}

normalize_cpu_clock_hz() {
  local in="${1:-}"
  [[ -z "$in" ]] && return 0
  awk -v s="$in" 'BEGIN{
    gsub(/^[ \t]+|[ \t]+$/, "", s);
    x=tolower(s);
    mult=1;
    if(x ~ /ghz$/){ mult=1000000000; sub(/ghz$/, "", x); }
    else if(x ~ /mhz$/){ mult=1000000; sub(/mhz$/, "", x); }
    else if(x ~ /khz$/){ mult=1000; sub(/khz$/, "", x); }
    else if(x ~ /hz$/){ mult=1; sub(/hz$/, "", x); }
    else if(x+0 < 100000){ mult=1000000; }
    printf "%.0f\n", (x+0)*mult;
  }'
}

PARSE_ONLY=0
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
if [[ "${1:-}" == "--parse-only" || "${1:-}" == "parse-only" ]]; then
  PARSE_ONLY=1
  if [[ -z "${2:-}" ]]; then
    echo "ERROR: --parse-only requires an existing OUT_DIR" >&2
    usage >&2
    exit 1
  fi
  OUT="$2"
  CPU_CLOCK_INPUT="${3:-${CPU_CLOCK_HZ:-}}"
  CMN_CLOCK_INPUT="${4:-${CMN_CLOCK_HZ:-}}"
  DURATION="parse-only"
  INTERVAL_MS="parse-only"
  CPU_LIST="parse-only"
  CMN_SEL="parse-only"
else

DURATION="${1:-10}"
INTERVAL_MS="${2:-500}"
CPU_LIST="${3:-0}"
CMN_SEL="${4:-0}"   # 0, 1, or both
CPU_CLOCK_INPUT="${5:-${CPU_CLOCK_HZ:-}}"
CMN_CLOCK_INPUT="${6:-${CMN_CLOCK_HZ:-}}"
fi
CPU_CLOCK_HZ_NORM="$(normalize_cpu_clock_hz "$CPU_CLOCK_INPUT")"
CMN_CLOCK_HZ_NORM="$(normalize_cpu_clock_hz "$CMN_CLOCK_INPUT")"

if [[ "$PARSE_ONLY" -eq 0 ]]; then
  OUT="${OUT:-/root/cmn_results/cbusy_snapshot_nomux_$(date +%Y%m%d_%H%M%S)}"
fi
mkdir -p "$OUT/raw" "$OUT/summary" "$OUT/meta"

echo "OUT=$OUT"
if [[ "$PARSE_ONLY" -eq 0 ]]; then
  echo "DURATION=$DURATION INTERVAL_MS=$INTERVAL_MS CPU_LIST=$CPU_LIST CMN_SEL=$CMN_SEL CPU_CLOCK_HZ=$CPU_CLOCK_HZ_NORM CMN_CLOCK_HZ=$CMN_CLOCK_HZ_NORM" | tee "$OUT/run_info.txt"
else
  echo "PARSE_ONLY=1 OUT=$OUT CPU_CLOCK_HZ=$CPU_CLOCK_HZ_NORM CMN_CLOCK_HZ=$CMN_CLOCK_HZ_NORM" | tee "$OUT/parse_only_info.txt"
fi

if [[ "$PARSE_ONLY" -eq 0 ]]; then
  case "$CMN_SEL" in
    0) CMNS=("arm_cmn_0") ;;
    1) CMNS=("arm_cmn_1") ;;
    both|all) CMNS=("arm_cmn_0" "arm_cmn_1") ;;
    *) echo "ERROR: CMN_SEL must be 0, 1, or both"; exit 1 ;;
  esac
else
  CMNS=("arm_cmn_0" "arm_cmn_1")
fi

if [[ "$PARSE_ONLY" -eq 0 ]]; then
perf list > "$OUT/meta/perf_list.txt" 2>&1 || true

join_events() {
  local out=""
  for ev in "$@"; do
    [[ -z "$out" ]] && out="$ev" || out="$out,$ev"
  done
  echo "$out"
}

event_ok() {
  local ev="$1"
  perf stat -a -e "$ev" -- sleep 0.01 >/dev/null 2>&1
}

filter_supported() {
  local name="$1"; shift
  local ok=()
  : > "$OUT/meta/${name}_supported.txt"
  : > "$OUT/meta/${name}_unsupported.txt"

  for ev in "$@"; do
    if event_ok "$ev"; then
      ok+=("$ev")
      echo "$ev" >> "$OUT/meta/${name}_supported.txt"
    else
      echo "$ev" >> "$OUT/meta/${name}_unsupported.txt"
    fi
  done

  printf '%s\n' "${ok[@]}"
}

run_pass_cpu() {
  local name="$1"; shift
  local events
  events="$(join_events "$@")"
  [[ -z "$events" ]] && { echo "SKIP CPU $name"; return 0; }

  echo "### CPU pass $name"
  perf stat -C "$CPU_LIST" -x, -I "$INTERVAL_MS" \
    -e "$events" \
    -o "$OUT/raw/${name}.csv" \
    -- sleep "$DURATION" \
    2>&1 | tee "$OUT/raw/${name}.log" || true
}

run_pass_cpu_per_node() {
  local name="$1"; shift
  local events
  events="$(join_events "$@")"
  [[ -z "$events" ]] && { echo "SKIP CPU $name"; return 0; }

  echo "### CPU per-node pass $name"
  perf stat -A -C "$CPU_LIST" -x, -I "$INTERVAL_MS" \
    -e "$events" \
    -o "$OUT/raw/${name}.csv" \
    -- sleep "$DURATION" \
    2>&1 | tee "$OUT/raw/${name}.log" || true
}

run_pass_sys() {
  local name="$1"; shift
  local events
  events="$(join_events "$@")"
  [[ -z "$events" ]] && { echo "SKIP SYS $name"; return 0; }

  echo "### SYS pass $name"
  perf stat -a -x, -I "$INTERVAL_MS" \
    -e "$events" \
    -o "$OUT/raw/${name}.csv" \
    -- sleep "$DURATION" \
    2>&1 | tee "$OUT/raw/${name}.log" || true
}

detect_cmn_pmus() {
  # Some kernels expose a single selected CMN PMU as arm_cmn/..., while others expose
  # arm_cmn_0/... and arm_cmn_1/... . Prefer numbered PMUs when present.
  local have0=0 have1=0 have_plain=0
  grep -qE '(^|[[:space:]])arm_cmn_0/' "$OUT/meta/perf_list.txt" 2>/dev/null && have0=1 || true
  grep -qE '(^|[[:space:]])arm_cmn_1/' "$OUT/meta/perf_list.txt" 2>/dev/null && have1=1 || true
  grep -qE '(^|[[:space:]])arm_cmn/' "$OUT/meta/perf_list.txt" 2>/dev/null && have_plain=1 || true

  if [[ "$have0" -eq 1 || "$have1" -eq 1 ]]; then
    case "$CMN_SEL" in
      0) CMNS=("arm_cmn_0") ;;
      1) CMNS=("arm_cmn_1") ;;
      both|all) CMNS=(); [[ "$have0" -eq 1 ]] && CMNS+=("arm_cmn_0"); [[ "$have1" -eq 1 ]] && CMNS+=("arm_cmn_1") ;;
    esac
  elif [[ "$have_plain" -eq 1 ]]; then
    # Unnumbered PMU: it represents the selected CMN instance exposed by the kernel.
    CMNS=("arm_cmn")
  fi
}

cmn_event_list() {
  local suffix="$1"
  for cmn in "${CMNS[@]}"; do
    echo "${cmn}/${suffix}/"
  done
}

cmn_event_with_hns_node() {
  local ev="$1"
  local nodeid="$2"
  # Named CMN events can be refined to one node by adding bynodeid/nodeid.
  # Kernel docs define bynodeid=1,nodeid=<CMN node ID> as the per-node selector.
  echo "${ev%/},bynodeid=1,nodeid=${nodeid}/"
}

cmn_event_list_hns_nodes() {
  local suffix="$1"
  local nodeid ev
  for ev in $(cmn_event_list "$suffix"); do
    for nodeid in "${HNS_NODE_ID_ARR[@]:-}"; do
      [[ -n "$nodeid" ]] || continue
      cmn_event_with_hns_node "$ev" "$nodeid"
    done
  done
}

parse_hns_node_ids() {
  HNS_NODE_ID_ARR=()
  local ids="${HNS_NODE_IDS:-$DEFAULT_HNS_NODE_IDS}"
  ids="${ids//,/ }"
  for id in $ids; do
    [[ -n "$id" ]] && HNS_NODE_ID_ARR+=("$id")
  done
  printf '%s
' "${HNS_NODE_ID_ARR[@]:-}" > "$OUT/meta/hns_node_ids_requested.txt"
}

# Detect numbered/plain PMUs now that helper functions exist.
detect_cmn_pmus
parse_hns_node_ids

# -----------------------------
# CPU events
# -----------------------------
run_pass_cpu cpu_core cycles instructions stall_backend_st
run_pass_cpu_per_node cpu_cbusy_a r198 r199
run_pass_cpu_per_node cpu_cbusy_b r19a r19b r19c
run_pass_cpu_per_node cpu_l2_tq_full r157

# -----------------------------
# CMN HN-S CBusy
# -----------------------------
CMN_HNS_CBUSY_SUFFIXES=(
  hns_cbusy00_all
  hns_cbusy01_all
  hns_cbusy02_all
  hns_cbusy03_all
)

CMN_HNS_CBUSY_CAND=()
for s in "${CMN_HNS_CBUSY_SUFFIXES[@]}"; do
  while read -r ev; do CMN_HNS_CBUSY_CAND+=("$ev"); done < <(cmn_event_list "$s")
done
mapfile -t CMN_HNS_CBUSY < <(filter_supported cmn_hns_cbusy "${CMN_HNS_CBUSY_CAND[@]}")
run_pass_sys cmn_hns_cbusy "${CMN_HNS_CBUSY[@]}"

# True per-HN-S CBusy. Requires CMN bynodeid/nodeid filtering support.
CMN_HNS_CBUSY_HNS_CAND=()
if [[ "${#HNS_NODE_ID_ARR[@]}" -gt 0 ]]; then
  for s in "${CMN_HNS_CBUSY_SUFFIXES[@]}"; do
    while read -r ev; do CMN_HNS_CBUSY_HNS_CAND+=("$ev"); done < <(cmn_event_list_hns_nodes "$s")
  done
fi
mapfile -t CMN_HNS_CBUSY_HNS < <(filter_supported cmn_hns_cbusy_hns "${CMN_HNS_CBUSY_HNS_CAND[@]:-}")
run_pass_sys cmn_hns_cbusy_hns "${CMN_HNS_CBUSY_HNS[@]:-}"

# -----------------------------
# CMN PoCQ
# -----------------------------
CMN_POCQ_SUFFIXES=(
  hns_pocq_class_occup_class0
  hns_pocq_class_occup_class1
  hns_pocq_class_occup_class2
  hns_pocq_class_occup_class3
  hns_pocq_class_retry_class0
  hns_pocq_class_retry_class1
  hns_pocq_class_retry_class2
  hns_pocq_class_retry_class3
  hns_pocq_retry_all
  hns_qos_pocq_occupancy_all
)

CMN_POCQ_CAND=()
for s in "${CMN_POCQ_SUFFIXES[@]}"; do
  while read -r ev; do CMN_POCQ_CAND+=("$ev"); done < <(cmn_event_list "$s")
done
mapfile -t CMN_POCQ < <(filter_supported cmn_pocq "${CMN_POCQ_CAND[@]}")
run_pass_sys cmn_pocq "${CMN_POCQ[@]}"

# Optional true per-HN-S PoCQ. Requires valid HNS_NODE_IDS because Linux perf
# needs CMN node IDs for bynodeid filtering.
CMN_POCQ_HNS_CAND=()
if [[ "${#HNS_NODE_ID_ARR[@]}" -gt 0 ]]; then
  for s in "${CMN_POCQ_SUFFIXES[@]}"; do
    while read -r ev; do CMN_POCQ_HNS_CAND+=("$ev"); done < <(cmn_event_list_hns_nodes "$s")
  done
fi
mapfile -t CMN_POCQ_HNS < <(filter_supported cmn_pocq_hns "${CMN_POCQ_HNS_CAND[@]:-}")
run_pass_sys cmn_pocq_hns "${CMN_POCQ_HNS[@]:-}"

# -----------------------------
# CMN SLC/cache
# -----------------------------
CMN_SLC_CAND=()
for s in \
  hns_slc_sf_cache_access_all \
  hns_cache_miss_all \
  hns_cache_fill_all \
  hns_slc_eviction_all
do
  while read -r ev; do CMN_SLC_CAND+=("$ev"); done < <(cmn_event_list "$s")
done
mapfile -t CMN_SLC < <(filter_supported cmn_slc "${CMN_SLC_CAND[@]}")
run_pass_sys cmn_slc "${CMN_SLC[@]}"

# -----------------------------
# DMC / memory-controller side candidates
# Includes true DMC events if kernel exposes them, plus SBSX/HNI/HNP/HNS proxies.
# -----------------------------
DMC_CAND=()

# Native DMC-ish PMUs from perf list, if present.
while read -r ev; do
  [[ -n "$ev" ]] && DMC_CAND+=("$ev")
done < <(
  awk '{print $1}' "$OUT/meta/perf_list.txt" | \
  grep -E '^(arm_dmc|dmc|ddr|mc)[^ ]*/.*(cbusy|stall|retry|throttle|occup|occ|full|ready|valid).*/$' || true
)

# CMN memory-side proxies.
for s in \
  hns_sn_throttle_all \
  hns_sn_throttle_read \
  hns_sn_throttle_write \
  hns_sn_throttle_min_all \
  hns_sn_throttle_min_read \
  hns_sn_throttle_min_write \
  hns_mc_reqs_local_all \
  hns_mc_reqs_remote_all \
  hns_mc_retries_local \
  hns_mc_retries_remote \
  hni_arvalid_no_arready \
  hni_awvalid_no_awready \
  hni_wvalid_no_wready \
  hni_txdat_stall \
  hni_txrsp_retryack \
  hnp_arvalid_no_arready \
  hnp_awvalid_no_awready \
  hnp_wvalid_no_wready \
  sbsx_arvalid_no_arready \
  sbsx_awvalid_no_awready \
  sbsx_wvalid_no_wready \
  sbsx_txrsp_retryack \
  sbsx_txdat_stall \
  sbsx_txrsp_stall \
  sbsx_rd_req \
  sbsx_wr_req \
  sbsx_rd_req_trkr_occ_cnt_ovfl \
  sbsx_wr_req_trkr_occ_cnt_ovfl \
  sbsx_rd_axi_trkr_occ_cnt_ovfl \
  sbsx_cmo_axi_trkr_occ_cnt_ovfl \
  sbsx_rdb_occ_cnt_ovfl \
  sbsx_wdb_occ_cnt_ovfl
do
  while read -r ev; do DMC_CAND+=("$ev"); done < <(cmn_event_list "$s")
done

mapfile -t DMC_EVENTS < <(filter_supported dmc_cbusy_mem_backpressure "${DMC_CAND[@]}")
run_pass_sys dmc_cbusy_mem_backpressure "${DMC_EVENTS[@]}"
fi

# -----------------------------
# Parser: raw avg, max, sample count, elapsed, running %
# -----------------------------
cat > "$OUT/parse_perf_csv.awk" <<'AWK'
BEGIN { FS=","; }
$1 ~ /^#/ { next; }
{
  ts=$1+0;
  v=$2;
  ev=$4;
  ena=$5+0;
  run=$6+0;
  ipc=$7;

  gsub(/^ +| +$/, "", v);
  gsub(/^ +| +$/, "", ev);

  if (ev == "" || v == "" || v ~ /<not/) next;

  val=v+0;
  pct=100.0;
  if (ena > 0 && run > 0) pct=(run/ena)*100.0;

  sum[ev]+=val;
  n[ev]++;
  if (val>max[ev]) max[ev]=val;
  if (ts>last_ts[ev]) last_ts[ev]=ts;

  run_sum[ev]+=pct;
  seen[ev]=1;
}
END {
  print "event,avg,max,samples,elapsed_s,avg_running_pct";
  for (e in seen) {
    if (n[e]==0)n[e]=1;
    printf "%s,%.0f,%.0f,%d,%.3f,%.2f\n",
      e, sum[e]/n[e], max[e], n[e], last_ts[e], run_sum[e]/n[e];
  }
}
AWK

for f in "$OUT"/raw/*.csv; do
  [[ -s "$f" ]] || continue
  base="$(basename "$f" .csv)"
  awk -f "$OUT/parse_perf_csv.awk" "$f" > "$OUT/summary/${base}_summary.csv"
done

# Ensure optional raw files exist so parse-only can work on partial logs.
for f in \
  "$OUT/raw/cpu_cbusy_a.csv" \
  "$OUT/raw/cpu_cbusy_b.csv" \
  "$OUT/raw/cpu_core.csv" \
  "$OUT/raw/cpu_l2_tq_full.csv" \
  "$OUT/raw/cmn_hns_cbusy.csv" \
  "$OUT/raw/cmn_pocq.csv" \
  "$OUT/raw/cmn_pocq_hns.csv" \
  "$OUT/raw/cmn_hns_cbusy_hns.csv"
do
  [[ -e "$f" ]] || : > "$f"
done

# CPU CBusy percent. MT CBusy r19c is intentionally excluded from the overall denominator.
awk -F, '
function trim(x){gsub(/^ +| +$/, "", x); return x}
function add(ev,val){
  if(ev=="r198"){r198+=val; n++}
  else if(ev=="r199"){r199+=val}
  else if(ev=="r19a"){r19a+=val}
  else if(ev=="r19b"){r19b+=val}
  else if(ev=="r19c"){r19c+=val; n19c++}
}
$1 ~ /^#/ {next}
{
  for(i=1;i<=NF;i++){
    f=trim($i);
    if(f ~ /^r(198|199|19a|19b|19c)$/){
      val=trim($(i-2));
      if(val != "" && val !~ /<not/) add(f, val+0);
    }
  }
}
END {
  if(n==0)n=1;
  if(n19c==0)n19c=n;
  raw=r198+r199+r19a+r19b;
  if(raw==0)raw=1;
  print "metric,value";
  printf "cpu_cbusy_non_mt_raw_avg,%.0f\n", raw/n;
  printf "cbusy0_r198_pct,%.2f\n", 100*r198/raw;
  printf "cbusy1_r199_pct,%.2f\n", 100*r199/raw;
  printf "cbusy2_r19a_pct,%.2f\n", 100*r19a/raw;
  printf "cbusy3_r19b_pct,%.2f\n", 100*r19b/raw;
  printf "MT_cbusy_r19c_excluded_avg,%.0f\n", r19c/n19c;
}' "$OUT/raw/cpu_cbusy_a.csv" "$OUT/raw/cpu_cbusy_b.csv" > "$OUT/summary/cpu_cbusy_percent.csv"

# CPU CBusy per CPU/core, same style as L2 TQ. Supports both new -A raw data and old aggregate raw data.
awk -F, '
function trim(x){gsub(/^ +| +$/, "", x); return x}
function record(node,ev,val){
  key=node "," ev;
  sum[key]+=val; n[key]++;
  if(val>max[key]) max[key]=val;
}
$1 ~ /^#/ {next}
{
  for(i=1;i<=NF;i++){
    ev=trim($i);
    if(ev ~ /^r(198|199|19a|19b|19c)$/){
      val=trim($(i-2)); node=trim($(i-3));
      if(node=="" || node ~ /^[0-9.]+$/) node="aggregate";
      if(val != "" && val !~ /<not/) record(node,ev,val+0);
    }
  }
}
END {
  print "node,metric,avg,max,samples";
  for(key in n){
    split(key,a,",");
    metric=a[2];
    if(metric=="r198") metric="cbusy0_r198";
    else if(metric=="r199") metric="cbusy1_r199";
    else if(metric=="r19a") metric="cbusy2_r19a";
    else if(metric=="r19b") metric="cbusy3_r19b";
    else if(metric=="r19c") metric="MT_cbusy_r19c_excluded";
    printf "%s,%s,%.0f,%.0f,%d\n", a[1], metric, sum[key]/n[key], max[key], n[key];
  }
}' "$OUT/raw/cpu_cbusy_a.csv" "$OUT/raw/cpu_cbusy_b.csv" > "$OUT/summary/cpu_cbusy_per_node_summary.csv"

# CPU CBusy percentages per CPU/core. Denominator excludes MT CBusy r19c.
awk -F, '
function trim(x){gsub(/^ +| +$/, "", x); return x}
function record(node,ev,val){
  sum[node "," ev]+=val;
  if(ev=="r198") samples[node]++;
}
$1 ~ /^#/ {next}
{
  for(i=1;i<=NF;i++){
    ev=trim($i);
    if(ev ~ /^r(198|199|19a|19b|19c)$/){
      val=trim($(i-2)); node=trim($(i-3));
      if(node=="" || node ~ /^[0-9.]+$/) node="aggregate";
      if(val != "" && val !~ /<not/) { record(node,ev,val+0); seen[node]=1; }
    }
  }
}
END {
  print "node,metric,value";
  for(node in seen){
    r198=sum[node ",r198"]; r199=sum[node ",r199"]; r19a=sum[node ",r19a"]; r19b=sum[node ",r19b"]; r19c=sum[node ",r19c"];
    raw=r198+r199+r19a+r19b;
    if(raw==0)raw=1;
    ns=samples[node]; if(ns==0)ns=1;
    printf "%s,cpu_cbusy_non_mt_raw_avg,%.0f\n", node, raw/ns;
    printf "%s,cbusy0_r198_pct,%.2f\n", node, 100*r198/raw;
    printf "%s,cbusy1_r199_pct,%.2f\n", node, 100*r199/raw;
    printf "%s,cbusy2_r19a_pct,%.2f\n", node, 100*r19a/raw;
    printf "%s,cbusy3_r19b_pct,%.2f\n", node, 100*r19b/raw;
    printf "%s,MT_cbusy_r19c_excluded_avg,%.0f\n", node, r19c/ns;
  }
}' "$OUT/raw/cpu_cbusy_a.csv" "$OUT/raw/cpu_cbusy_b.csv" > "$OUT/summary/cpu_cbusy_per_node_percent.csv"

# CPU core
awk -F, '
$4=="cycles"{cyc+=$2;n++}
$4=="instructions"{ins+=$2}
$4=="stall_backend_st"{stall+=$2}
END {
  if(n==0)n=1;
  print "metric,value";
  printf "cycles_avg,%.0f\n", cyc/n;
  printf "instructions_avg,%.0f\n", ins/n;
  printf "ipc,%.4f\n", (cyc>0 ? ins/cyc : 0);
  printf "stall_backend_avg,%.0f\n", stall/n;
}' "$OUT/raw/cpu_core.csv" > "$OUT/summary/cpu_core_summary.csv"

# L2 TQ full
awk -F, '
$4=="r157"{tq+=$2;n++}
END {
  if(n==0)n=1;
  print "metric,value";
  printf "L2_TQ_FULL_r157_avg,%.0f\n", tq/n;
}' "$OUT/raw/cpu_l2_tq_full.csv" > "$OUT/summary/cpu_l2_tq_full_summary.csv"

# Alias unnumbered arm_cmn/... to arm_cmn_0 or arm_cmn_1 when run_info records CMN_SEL.
CMN_ALIAS="arm_cmn"
if [[ -f "$OUT/run_info.txt" ]]; then
  case "$(sed -n 's/.*CMN_SEL=\([^ ]*\).*/\1/p' "$OUT/run_info.txt" | tail -1)" in
    0) CMN_ALIAS="arm_cmn_0" ;;
    1) CMN_ALIAS="arm_cmn_1" ;;
  esac
fi

# CMN HN-S CBusy percent
awk -F, '
/hns_cbusy00_all/{cb0+=$2;n++}
/hns_cbusy01_all/{cb1+=$2}
/hns_cbusy02_all/{cb2+=$2}
/hns_cbusy03_all/{cb3+=$2}
END {
  if(n==0)n=1;
  total=cb0+cb1+cb2+cb3;
  if(total==0)total=1;
  print "metric,value";
  printf "hns_cbusy_total_avg,%.0f\n", total/n;
  printf "hns_cbusy00_pct,%.2f\n", 100*cb0/total;
  printf "hns_cbusy01_pct,%.2f\n", 100*cb1/total;
  printf "hns_cbusy02_pct,%.2f\n", 100*cb2/total;
  printf "hns_cbusy03_pct,%.2f\n", 100*cb3/total;
}' "$OUT/raw/cmn_hns_cbusy.csv" > "$OUT/summary/cmn_hns_cbusy_percent.csv"

# CMN HN-S CBusy per HN-S nodeid, when raw events include bynodeid/nodeid selectors.
awk -F, -v cmn_alias="$CMN_ALIAS" '
{
  ts=$1+0; val=$2; ev=""; ena=0; run=0;
  gsub(/^ +| +$/, "", val);
  for(i=1;i<=NF;i++){
    f=$i; gsub(/^ +| +$/, "", f);
    if(f ~ /^arm_cmn(_[0-9]+)?\//){
      ev=f; j=i+1;
      while(j<=NF && ev !~ /\/$/){ ev=ev "," $j; j++; }
      ena=$(j)+0; run=$(j+1)+0;
      break;
    }
  }
  if(ev=="" || val=="" || val ~ /<not/) next;
  if(ev !~ /hns_cbusy[0-9][0-9]_all/ || ev !~ /nodeid=/) next;
  cmn="unknown_cmn"; short=ev; hns="unknown_hns";
  if(match(ev, /arm_cmn_[0-9]+/)) { cmn=substr(ev,RSTART,RLENGTH); gsub(/^arm_cmn_[0-9]+\//,"",short); }
  else if(match(ev, /arm_cmn\//)) { cmn=cmn_alias; gsub(/^arm_cmn\//,"",short); }
  if(match(ev, /nodeid=0x[0-9a-fA-F]+/)) hns=substr(ev,RSTART+7,RLENGTH-7);
  else if(match(ev, /nodeid=[0-9]+/)) hns=substr(ev,RSTART+7,RLENGTH-7);
  sub(/,bynodeid=1,nodeid=[^\/]+\/$/, "", short);
  gsub(/\/$/, "", short);
  key=cmn "," hns "," short;
  pct=100.0; if(ena>0 && run>0) pct=(run/ena)*100.0;
  sum[key]+=val+0; n[key]++; if((val+0)>max[key]) max[key]=val+0;
  if(ts>last_ts[key]) last_ts[key]=ts; run_sum[key]+=pct;
}
END {
  print "cmn,hns_nodeid,event,avg,max,samples,elapsed_s,avg_running_pct";
  for(key in n) printf "%s,%.0f,%.0f,%d,%.3f,%.2f\n", key, sum[key]/n[key], max[key], n[key], last_ts[key], run_sum[key]/n[key];
}' "$OUT/raw/cmn_hns_cbusy_hns.csv" > "$OUT/summary/cmn_hns_cbusy_per_hns_summary.csv" 2>/dev/null || true

# CMN HN-S CBusy per HN-S percent split. Percentages are per CMN+HNS nodeid.
# Also create a detailed file that keeps one row per cbusy event and adds pct_of_node_total.
awk -F, '
NR==1{next}
{
  cmn=$1; hns=$2; ev=$3; avg=$4+0; maxv=$5+0; samples=$6+0; elapsed=$7+0; runpct=$8+0;
  key=cmn "," hns; rowkey=key "," ev;
  avgv[rowkey]=avg; maxval[rowkey]=maxv; samplev[rowkey]=samples; elapsedv[rowkey]=elapsed; runpctv[rowkey]=runpct;
  if(ev ~ /hns_cbusy00_all/) cb0[key]+=avg;
  else if(ev ~ /hns_cbusy01_all/) cb1[key]+=avg;
  else if(ev ~ /hns_cbusy02_all/) cb2[key]+=avg;
  else if(ev ~ /hns_cbusy03_all/) cb3[key]+=avg;
  seen[key]=1; seenrow[rowkey]=1;
}
END{
  print "cmn,hns_nodeid,metric,value" > PCTFILE;
  print "cmn,hns_nodeid,event,avg,pct_of_node_total,max,samples,elapsed_s,avg_running_pct" > DETAILFILE;
  for(k in seen){
    actual_total=cb0[k]+cb1[k]+cb2[k]+cb3[k]; total=actual_total; if(total==0) total=1;
    print k ",hns_cbusy_total_avg," actual_total >> PCTFILE;
    printf "%s,hns_cbusy00_pct,%.2f\n", k, 100*cb0[k]/total >> PCTFILE;
    printf "%s,hns_cbusy01_pct,%.2f\n", k, 100*cb1[k]/total >> PCTFILE;
    printf "%s,hns_cbusy02_pct,%.2f\n", k, 100*cb2[k]/total >> PCTFILE;
    printf "%s,hns_cbusy03_pct,%.2f\n", k, 100*cb3[k]/total >> PCTFILE;
  }
  for(r in seenrow){
    split(r,a,","); k=a[1] "," a[2]; ev=a[3];
    actual_total=cb0[k]+cb1[k]+cb2[k]+cb3[k]; total=actual_total; if(total==0) total=1;
    pct=100*avgv[r]/total;
    printf "%s,%s,%s,%.0f,%.2f,%.0f,%d,%.3f,%.2f\n", a[1],a[2],ev,avgv[r],pct,maxval[r],samplev[r],elapsedv[r],runpctv[r] >> DETAILFILE;
  }
}' PCTFILE="$OUT/summary/cmn_hns_cbusy_per_hns_percent.csv" \
   DETAILFILE="$OUT/summary/cmn_hns_cbusy_per_hns_summary_with_pct.csv" \
   "$OUT/summary/cmn_hns_cbusy_per_hns_summary.csv" 2>/dev/null || true

# L2 TQ full per CPU node/core. If old raw data was not captured with -A, emit aggregate.
# Optional normalized percentage uses CPU_CLOCK_HZ and the perf interval:
#   L2_TQ_FULL_pct = count / (CPU_CLOCK_HZ * interval_seconds) * 100
# Pass CPU clock as arg 5, env CPU_CLOCK_HZ, or with --parse-only OUT_DIR CPU_CLOCK.
L2_INTERVAL_MS="$INTERVAL_MS"
if [[ "$PARSE_ONLY" -eq 1 && -f "$OUT/run_info.txt" ]]; then
  L2_INTERVAL_MS="$(sed -n 's/.*INTERVAL_MS=\([^ ]*\).*/\1/p' "$OUT/run_info.txt" | tail -1)"
fi
if [[ -z "${CPU_CLOCK_HZ_NORM:-}" && -f "$OUT/run_info.txt" ]]; then
  CPU_CLOCK_HZ_NORM="$(sed -n 's/.*CPU_CLOCK_HZ=\([^ ]*\).*/\1/p' "$OUT/run_info.txt" | tail -1)"
fi
: "${CPU_CLOCK_HZ_NORM:=}"
awk -F, -v clk_hz="$CPU_CLOCK_HZ_NORM" -v interval_ms="$L2_INTERVAL_MS" -v pctfile="$OUT/summary/cpu_l2_tq_full_per_node_with_pct.csv" '
{
  ev=""; val=""; node="aggregate";
  for(i=1;i<=NF;i++){
    gsub(/^ +| +$/, "", $i);
    if($i=="r157"){
      ev=$i;
      val=$(i-2);
      node=$(i-3);
      if(node=="" || node ~ /^[0-9.]+$/) node="aggregate";
    }
  }
  # Old non -A layout is: time,value,,r157,...
  if(ev=="" && $4=="r157"){ ev=$4; val=$2; node="aggregate"; }
  if(ev=="" || val=="" || val ~ /<not/) next;
  sum[node]+=val+0;
  n[node]++;
  if((val+0)>max[node]) max[node]=val+0;
}
END {
  print "node,metric,avg,max,samples";
  print "node,metric,avg,max,samples,cpu_clock_hz,interval_s,l2_tq_pct_avg,l2_tq_pct_max" > pctfile;
  interval_s=(interval_ms+0)/1000.0;
  denom=(clk_hz+0)*interval_s;
  for(node in n){
    avg=sum[node]/n[node]; maxv=max[node];
    printf "%s,L2_TQ_FULL_r157,%.0f,%.0f,%d\n", node, avg, maxv, n[node];
    if(denom>0){
      printf "%s,L2_TQ_FULL_r157,%.0f,%.0f,%d,%.0f,%.6f,%.2f,%.2f\n", node, avg, maxv, n[node], clk_hz+0, interval_s, 100*avg/denom, 100*maxv/denom >> pctfile;
    } else {
      printf "%s,L2_TQ_FULL_r157,%.0f,%.0f,%d,,%.6f,,\n", node, avg, maxv, n[node], interval_s >> pctfile;
    }
  }
}' "$OUT/raw/cpu_l2_tq_full.csv" > "$OUT/summary/cpu_l2_tq_full_per_node.csv" 2>/dev/null || true

# CMN PoCQ occupancy normalization uses CMN_CLOCK_HZ and the perf interval:
#   pocq_occupancy_pct = occupancy_count / (CMN_CLOCK_HZ * interval_seconds) * 100
POCQ_INTERVAL_MS="$INTERVAL_MS"
if [[ "$PARSE_ONLY" -eq 1 && -f "$OUT/run_info.txt" ]]; then
  POCQ_INTERVAL_MS="$(sed -n 's/.*INTERVAL_MS=\([^ ]*\).*/\1/p' "$OUT/run_info.txt" | tail -1)"
fi
if [[ -z "${CMN_CLOCK_HZ_NORM:-}" && -f "$OUT/run_info.txt" ]]; then
  CMN_CLOCK_HZ_NORM="$(sed -n 's/.*CMN_CLOCK_HZ=\([^ ]*\).*/\1/p' "$OUT/run_info.txt" | tail -1)"
fi
: "${CMN_CLOCK_HZ_NORM:=}"

# CMN PoCQ per CMN PMU/node. This keeps arm_cmn_0 and arm_cmn_1 separate when present.
awk -F, -v cmn_alias="$CMN_ALIAS" -v clk_hz="$CMN_CLOCK_HZ_NORM" -v interval_ms="$POCQ_INTERVAL_MS" -v pctfile="$OUT/summary/cmn_pocq_occupancy_per_node_with_pct.csv" '
{
  ts=$1+0;
  ev=$4;
  val=$2;
  ena=$5+0;
  run=$6+0;
  gsub(/^ +| +$/, "", ev);
  gsub(/^ +| +$/, "", val);
  if(ev=="" || val=="" || val ~ /<not/) next;
  if(ev !~ /pocq/) next;
  cmn="unknown_cmn";
  short=ev;
  if(match(ev, /arm_cmn_[0-9]+/)) {
    cmn=substr(ev, RSTART, RLENGTH);
    gsub(/^arm_cmn_[0-9]+\//, "", short);
  } else if(match(ev, /arm_cmn\//)) {
    cmn=cmn_alias;
    gsub(/^arm_cmn\//, "", short);
  }
  gsub(/\/$/, "", short);
  key=cmn "," short;
  pct=100.0;
  if(ena>0 && run>0) pct=(run/ena)*100.0;
  sum[key]+=val+0;
  n[key]++;
  if((val+0)>max[key]) max[key]=val+0;
  if(ts>last_ts[key]) last_ts[key]=ts;
  run_sum[key]+=pct;
}
END {
  print "cmn,event,avg,max,samples,elapsed_s,avg_running_pct";
  print "cmn,event,avg,max,samples,cmn_clock_hz,interval_s,pocq_occupancy_pct_avg,pocq_occupancy_pct_max" > pctfile;
  interval_s=(interval_ms+0)/1000.0; denom=(clk_hz+0)*interval_s;
  for(key in n){
    avg=sum[key]/n[key]; maxv=max[key];
    printf "%s,%.0f,%.0f,%d,%.3f,%.2f\n", key, avg, maxv, n[key], last_ts[key], run_sum[key]/n[key];
    split(key,a,","); ev=a[2];
    if(ev ~ /occup/) {
      if(denom>0) printf "%s,%.0f,%.0f,%d,%.0f,%.6f,%.2f,%.2f\n", key, avg, maxv, n[key], clk_hz+0, interval_s, 100*avg/denom, 100*maxv/denom >> pctfile;
      else printf "%s,%.0f,%.0f,%d,,%.6f,,\n", key, avg, maxv, n[key], interval_s >> pctfile;
    }
  }
}' "$OUT/raw/cmn_pocq.csv" > "$OUT/summary/cmn_pocq_per_node_summary.csv" 2>/dev/null || true


# CMN PoCQ per HN-S node, when raw events include bynodeid/nodeid selectors.
# Note: perf -x, does not quote commas inside event names, so reconstruct the
# event field by scanning for arm_cmn... through nodeid=.../.
awk -F, -v cmn_alias="$CMN_ALIAS" -v clk_hz="$CMN_CLOCK_HZ_NORM" -v interval_ms="$POCQ_INTERVAL_MS" -v pctfile="$OUT/summary/cmn_pocq_occupancy_per_hns_with_pct.csv" '
{
  ts=$1+0; val=$2; ev=""; ena=0; run=0;
  gsub(/^ +| +$/, "", val);
  for(i=1;i<=NF;i++){
    f=$i; gsub(/^ +| +$/, "", f);
    if(f ~ /^arm_cmn(_[0-9]+)?\//){
      ev=f; j=i+1;
      while(j<=NF && ev !~ /\/$/){ ev=ev "," $j; j++; }
      ena=$(j)+0; run=$(j+1)+0;
      break;
    }
  }
  if(ev=="" || val=="" || val ~ /<not/) next;
  if(ev !~ /pocq/ || ev !~ /nodeid=/) next;
  cmn="unknown_cmn"; short=ev; hns="unknown_hns";
  if(match(ev, /arm_cmn_[0-9]+/)) { cmn=substr(ev,RSTART,RLENGTH); gsub(/^arm_cmn_[0-9]+\//,"",short); }
  else if(match(ev, /arm_cmn\//)) { cmn=cmn_alias; gsub(/^arm_cmn\//,"",short); }
  if(match(ev, /nodeid=0x[0-9a-fA-F]+/)) hns=substr(ev,RSTART+7,RLENGTH-7);
  else if(match(ev, /nodeid=[0-9]+/)) hns=substr(ev,RSTART+7,RLENGTH-7);
  sub(/,bynodeid=1,nodeid=[^\/]+\/$/, "", short);
  gsub(/\/$/, "", short);
  key=cmn "," hns "," short;
  pct=100.0; if(ena>0 && run>0) pct=(run/ena)*100.0;
  sum[key]+=val+0; n[key]++; if((val+0)>max[key]) max[key]=val+0;
  if(ts>last_ts[key]) last_ts[key]=ts; run_sum[key]+=pct;
}
END {
  print "cmn,hns_nodeid,event,avg,max,samples,elapsed_s,avg_running_pct";
  print "cmn,hns_nodeid,event,avg,max,samples,cmn_clock_hz,interval_s,pocq_occupancy_pct_avg,pocq_occupancy_pct_max" > pctfile;
  interval_s=(interval_ms+0)/1000.0; denom=(clk_hz+0)*interval_s;
  for(key in n) {
    avg=sum[key]/n[key]; maxv=max[key];
    printf "%s,%.0f,%.0f,%d,%.3f,%.2f\n", key, avg, maxv, n[key], last_ts[key], run_sum[key]/n[key];
    split(key,a,","); ev=a[3];
    if(ev ~ /occup/) {
      if(denom>0) printf "%s,%.0f,%.0f,%d,%.0f,%.6f,%.2f,%.2f\n", key, avg, maxv, n[key], clk_hz+0, interval_s, 100*avg/denom, 100*maxv/denom >> pctfile;
      else printf "%s,%.0f,%.0f,%d,,%.6f,,\n", key, avg, maxv, n[key], interval_s >> pctfile;
    }
  }
}' "$OUT/raw/cmn_pocq_hns.csv" > "$OUT/summary/cmn_pocq_per_hns_summary.csv" 2>/dev/null || true

# Always create combined summaries.
# Build via a temporary file and explicitly skip combined_summary.csv so the
# loop never reads the file it is currently generating.
combined_tmp="$OUT/summary/combined_summary.csv.tmp.$$"
{
  echo "section,metric,value"
  find "$OUT/summary" -maxdepth 1 -type f \( \
      -name '*_summary.csv' -o \
      -name '*_percent.csv' -o \
      -name '*_per_node.csv' -o \
      -name '*_per_node_with_pct.csv' -o \
      -name '*_per_hns_summary.csv' -o \
      -name '*_per_hns_percent.csv' -o \
      -name '*_per_hns_with_pct.csv' \
    \) ! -name 'combined_summary.csv' ! -name 'combined_summary.csv.tmp.*' | sort | while read -r f; do
    [[ -s "$f" ]] || continue
    sec="$(basename "$f" .csv)"
    awk -F, -v sec="$sec" '
      NR==1{h=$0; next}
      h ~ /^cmn,hns_nodeid,event,avg,max,samples,cmn_clock_hz,interval_s,pocq_occupancy_pct_avg,pocq_occupancy_pct_max/ {
        print sec "," $1 ":" $2 ":" $3 ":pocq_occupancy_pct_avg," $9;
        print sec "," $1 ":" $2 ":" $3 ":pocq_occupancy_pct_max," $10;
        print sec "," $1 ":" $2 ":" $3 ":avg," $4;
        next
      }
      h ~ /^cmn,event,avg,max,samples,cmn_clock_hz,interval_s,pocq_occupancy_pct_avg,pocq_occupancy_pct_max/ {
        print sec "," $1 ":" $2 ":pocq_occupancy_pct_avg," $8;
        print sec "," $1 ":" $2 ":pocq_occupancy_pct_max," $9;
        print sec "," $1 ":" $2 ":avg," $3;
        next
      }
      h ~ /^node,metric,avg,max,samples,cpu_clock_hz,interval_s,l2_tq_pct_avg,l2_tq_pct_max/ {
        print sec "," $1 ":" $2 ":l2_tq_pct_avg," $8;
        print sec "," $1 ":" $2 ":l2_tq_pct_max," $9;
        print sec "," $1 ":" $2 ":avg," $3;
        next
      }
      h ~ /^cmn,hns_nodeid,event,/ {print sec "," $1 ":" $2 ":" $3 "," $4; next}
      h ~ /^cmn,hns_nodeid,metric,/ {print sec "," $1 ":" $2 ":" $3 "," $4; next}
      h ~ /^cmn,event,/ {print sec "," $1 ":" $2 "," $3; next}
      h ~ /^node,metric,/ {print sec "," $1 ":" $2 "," $3; next}
      {print sec "," $1 "," $2}
    ' "$f"
  done
} > "$combined_tmp"
mv -f "$combined_tmp" "$OUT/summary/combined_summary.csv"

# Human-readable compact summary.
{
  echo "=== CPU core ==="
  cat "$OUT/summary/cpu_core_summary.csv"
  echo
  echo "=== CPU CBusy split (r19c excluded from total) ==="
  cat "$OUT/summary/cpu_cbusy_percent.csv"
  echo
  echo "=== CPU CBusy per CPU/core ==="
  [[ -f "$OUT/summary/cpu_cbusy_per_node_summary.csv" ]] && cat "$OUT/summary/cpu_cbusy_per_node_summary.csv"
  echo
  [[ -f "$OUT/summary/cpu_cbusy_per_node_percent.csv" ]] && cat "$OUT/summary/cpu_cbusy_per_node_percent.csv"
  echo
  echo "=== L2_TQ_FULL ==="
  [[ -f "$OUT/summary/cpu_l2_tq_full_per_node.csv" ]] && cat "$OUT/summary/cpu_l2_tq_full_per_node.csv" || cat "$OUT/summary/cpu_l2_tq_full_summary.csv"
  if [[ -f "$OUT/summary/cpu_l2_tq_full_per_node_with_pct.csv" ]]; then echo; echo "--- L2_TQ_FULL normalized by CPU clock ---"; cat "$OUT/summary/cpu_l2_tq_full_per_node_with_pct.csv"; fi
  echo
  echo "=== CMN HN-S CBusy split ==="
  cat "$OUT/summary/cmn_hns_cbusy_percent.csv"
  if [[ -f "$OUT/summary/cmn_hns_cbusy_per_hns_summary.csv" ]]; then echo; echo "--- per HN-S nodeid raw ---"; cat "$OUT/summary/cmn_hns_cbusy_per_hns_summary.csv"; fi
  if [[ -f "$OUT/summary/cmn_hns_cbusy_per_hns_summary_with_pct.csv" ]]; then echo; echo "--- per HN-S nodeid with percent ---"; cat "$OUT/summary/cmn_hns_cbusy_per_hns_summary_with_pct.csv"; fi
  if [[ -f "$OUT/summary/cmn_hns_cbusy_per_hns_percent.csv" ]]; then echo; echo "--- per HN-S nodeid percent compact ---"; cat "$OUT/summary/cmn_hns_cbusy_per_hns_percent.csv"; fi
  echo
  echo "=== PoCQ ==="
  [[ -f "$OUT/summary/cmn_pocq_per_node_summary.csv" ]] && cat "$OUT/summary/cmn_pocq_per_node_summary.csv"
  if [[ -f "$OUT/summary/cmn_pocq_per_hns_summary.csv" ]]; then echo; echo "--- per HN-S nodeid ---"; cat "$OUT/summary/cmn_pocq_per_hns_summary.csv"; fi
  if [[ -f "$OUT/summary/cmn_pocq_occupancy_per_node_with_pct.csv" ]]; then echo; echo "--- PoCQ occupancy normalized by CMN clock ---"; cat "$OUT/summary/cmn_pocq_occupancy_per_node_with_pct.csv"; fi
  if [[ -f "$OUT/summary/cmn_pocq_occupancy_per_hns_with_pct.csv" ]]; then echo; echo "--- PoCQ occupancy per HN-S normalized by CMN clock ---"; cat "$OUT/summary/cmn_pocq_occupancy_per_hns_with_pct.csv"; fi
  [[ -f "$OUT/summary/cmn_pocq_summary.csv" ]] && { echo; echo "--- raw event summary ---"; cat "$OUT/summary/cmn_pocq_summary.csv"; }
  echo
  echo "=== SLC/cache ==="
  [[ -f "$OUT/summary/cmn_slc_summary.csv" ]] && cat "$OUT/summary/cmn_slc_summary.csv"
  echo
  echo "=== DMC / memory backpressure / CBusy candidates ==="
  [[ -f "$OUT/summary/dmc_cbusy_mem_backpressure_summary.csv" ]] && cat "$OUT/summary/dmc_cbusy_mem_backpressure_summary.csv"
} > "$OUT/summary/summary.txt"

echo
echo "DONE"
echo "OUT=$OUT"
echo
echo "Main outputs:"
echo "$OUT/summary/summary.txt"
echo "$OUT/summary/combined_summary.csv"
echo
echo "Supported/unsupported:"
echo "$OUT/meta/*_supported.txt"
echo "$OUT/meta/*_unsupported.txt"
