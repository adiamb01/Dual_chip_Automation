#!/usr/bin/env bash
set -euo pipefail

DURATION="${1:-10}"
INTERVAL_MS="${2:-500}"
CPU_LIST="${3:-0}"
CMN_SEL="${4:-0}"   # 0, 1, or both

OUT="${OUT:-/root/cmn_results/cbusy_snapshot_nomux_$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$OUT/raw" "$OUT/summary" "$OUT/meta"

echo "OUT=$OUT"
echo "DURATION=$DURATION INTERVAL_MS=$INTERVAL_MS CPU_LIST=$CPU_LIST CMN_SEL=$CMN_SEL" | tee "$OUT/run_info.txt"

case "$CMN_SEL" in
  0) CMNS=("arm_cmn_0") ;;
  1) CMNS=("arm_cmn_1") ;;
  both|all) CMNS=("arm_cmn_0" "arm_cmn_1") ;;
  *) echo "ERROR: CMN_SEL must be 0, 1, or both"; exit 1 ;;
esac

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

cmn_event_list() {
  local suffix="$1"
  for cmn in "${CMNS[@]}"; do
    echo "${cmn}/${suffix}/"
  done
}

# -----------------------------
# CPU events
# -----------------------------
run_pass_cpu cpu_core cycles instructions stall_backend_st
run_pass_cpu cpu_cbusy_a r198 r199
run_pass_cpu cpu_cbusy_b r19a r19b r19c
run_pass_cpu cpu_l2_tq_full r157

# -----------------------------
# CMN HN-S CBusy
# -----------------------------
CMN_HNS_CBUSY_CAND=()
for s in hns_cbusy00_all hns_cbusy01_all hns_cbusy02_all hns_cbusy03_all; do
  while read -r ev; do CMN_HNS_CBUSY_CAND+=("$ev"); done < <(cmn_event_list "$s")
done
mapfile -t CMN_HNS_CBUSY < <(filter_supported cmn_hns_cbusy "${CMN_HNS_CBUSY_CAND[@]}")
run_pass_sys cmn_hns_cbusy "${CMN_HNS_CBUSY[@]}"

# -----------------------------
# CMN PoCQ
# -----------------------------
CMN_POCQ_CAND=()
for s in \
  hns_pocq_class_occup_class0 \
  hns_pocq_class_occup_class1 \
  hns_pocq_class_occup_class2 \
  hns_pocq_class_occup_class3 \
  hns_pocq_class_retry_class0 \
  hns_pocq_class_retry_class1 \
  hns_pocq_class_retry_class2 \
  hns_pocq_class_retry_class3 \
  hns_pocq_retry_all \
  hns_qos_pocq_occupancy_all
do
  while read -r ev; do CMN_POCQ_CAND+=("$ev"); done < <(cmn_event_list "$s")
done
mapfile -t CMN_POCQ < <(filter_supported cmn_pocq "${CMN_POCQ_CAND[@]}")
run_pass_sys cmn_pocq "${CMN_POCQ[@]}"

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

# CPU CBusy percent
awk -F, '
FILENAME ~ /cpu_cbusy_a.csv/ {
  if($4=="r198"){r198+=$2;n++}
  if($4=="r199"){r199+=$2}
}
FILENAME ~ /cpu_cbusy_b.csv/ {
  if($4=="r19a"){r19a+=$2}
  if($4=="r19b"){r19b+=$2}
  if($4=="r19c"){r19c+=$2}
}
END {
  if(n==0)n=1;
  raw=r198+r199+r19a+r19b+r19c;
  if(raw==0)raw=1;
  print "metric,value";
  printf "cpu_cbusy_raw_avg,%.0f\n", raw/n;
  printf "cbusy0_r198_pct,%.2f\n", 100*r198/raw;
  printf "cbusy1_r199_pct,%.2f\n", 100*r199/raw;
  printf "cbusy2_r19a_pct,%.2f\n", 100*r19a/raw;
  printf "cbusy3_r19b_pct,%.2f\n", 100*r19b/raw;
  printf "MT_cbusy_r19c_pct,%.2f\n", 100*r19c/raw;
}' "$OUT/raw/cpu_cbusy_a.csv" "$OUT/raw/cpu_cbusy_b.csv" > "$OUT/summary/cpu_cbusy_percent.csv"

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

# Always create combined summaries.
{
  echo "section,metric,value"
  for f in "$OUT"/summary/*_summary.csv "$OUT"/summary/*_percent.csv; do
    [[ -s "$f" ]] || continue
    sec="$(basename "$f" .csv)"
    awk -F, -v sec="$sec" 'NR>1{print sec "," $1 "," $2}' "$f"
  done
} > "$OUT/summary/combined_summary.csv"

# Human-readable compact summary.
{
  echo "=== CPU core ==="
  cat "$OUT/summary/cpu_core_summary.csv"
  echo
  echo "=== CPU CBusy split ==="
  cat "$OUT/summary/cpu_cbusy_percent.csv"
  echo
  echo "=== L2_TQ_FULL ==="
  cat "$OUT/summary/cpu_l2_tq_full_summary.csv"
  echo
  echo "=== CMN HN-S CBusy split ==="
  cat "$OUT/summary/cmn_hns_cbusy_percent.csv"
  echo
  echo "=== PoCQ ==="
  [[ -f "$OUT/summary/cmn_pocq_summary.csv" ]] && cat "$OUT/summary/cmn_pocq_summary.csv"
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
