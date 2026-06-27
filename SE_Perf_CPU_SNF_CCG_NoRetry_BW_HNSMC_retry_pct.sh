#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="$(pwd)"
RAW_FILE=""
XLSX_FILE=""
COMBINED_FILE=""
PARSE_ONLY=0
RUN_ONLY=0
INPUT_RAW=""
SLEEP_SECS="0.2"
KEEP_COMBINED=1
CMN_INDICES="0,1"

# Dual-chip mapping: arm_cmn_0 uses CPU cores 0-63, arm_cmn_1 uses CPU cores 64-127.
SNF_NODEIDS=(
  0x8 0x10 0x18 0x20 0x28 0x30 0x408 0x410 0x418 0x420 0x428 0x430
)

# SN-F bandwidth watchpoints, no retry-counted write path.
# Read BW:          wp_val=0x800002000
# Write BW no retry: wp_val=0x80000e800
SNF_READ_WP=(0x800002000)
SNF_WRITE_NORETRY_WP=(0x80000e800)
SNF_WP_MASK=0xfffffff7fffc07ff

# CCG C2C bandwidth watchpoints. These are kept from the original CCG flow.
CCG_NODEIDS=(0x0 0x80 0x100 0x180 0x280 0x300 0x380 0x400)
CCG_READ_WP=(0x800013000)
CCG_WRITE_CLEAN_WP=(0x800003800 0x80000d800 0x80000b800 0x80000c800)
CCG_WRITE_DIRTY_WP=(0x80000a800 0x800021000)
CCG_WP_MASK=0xfffffff7fffc07ff

usage() {
  cat <<'USAGE'
Usage:
  ./SE_Perf_CPU_SNF_NoRetry_BW.sh [options]

Options:
  --out-dir DIR          Output directory. Default: current directory
  --raw FILE             Raw output file. Default: <out-dir>/raw_perf_stats.txt
  --xlsx FILE            Excel workbook. Default: <out-dir>/parsed_perf_stats.xlsx
  --combined FILE        Combined commands file. Default: <out-dir>/combined_perf_commands.txt
  --sleep SECS           Sleep duration per perf command. Default: 0.2
  --cmn LIST             CMN indices to run/parse: 0, 1, or 0,1. Default: 0,1
  --cmn-indices LIST     Alias for --cmn
  --parse-only FILE      Skip perf execution and only parse an existing raw file
  --run-only             Only generate combined commands and raw output; skip Excel parsing
  --no-combined          Do not keep combined command file on disk
  -h, --help             Show this help

Collected metrics:
  CPU PMU read/write: armv8_pmuv3_0 event 0x60 / 0x61
  SN-F read BW:       watchpoint_down wp_dev_sel=0 wp_grp=2 wp_val=0x800002000
  SN-F write BW:      watchpoint_down wp_dev_sel=0 wp_grp=2 wp_val=0x80000e800
                      This is the no-retry SN-F write BW watchpoint.
  HNS MC SN counters: hns_mc_reqs_local_sn/remote_sn and hns_mc_retries_local/remote
  CCG C2C BW:         watchpoint_up/down wp_dev_sel=1 wp_grp=2
                      read=0x800013000, write clean/dirty C2C values
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --raw) RAW_FILE="$2"; shift 2 ;;
    --xlsx) XLSX_FILE="$2"; shift 2 ;;
    --combined) COMBINED_FILE="$2"; shift 2 ;;
    --sleep) SLEEP_SECS="$2"; shift 2 ;;
    --cmn|--cmn-indices) CMN_INDICES="$2"; shift 2 ;;
    --parse-only) PARSE_ONLY=1; INPUT_RAW="$2"; shift 2 ;;
    --run-only) RUN_ONLY=1; shift ;;
    --no-combined) KEEP_COMBINED=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

IFS=',' read -r -a SELECTED_CMNS <<< "$CMN_INDICES"
for cmn in "${SELECTED_CMNS[@]}"; do
  if [[ "$cmn" != "0" && "$cmn" != "1" ]]; then
    echo "Invalid --cmn value '$cmn'. Use 0, 1, or 0,1." >&2
    exit 1
  fi
done

mkdir -p "$OUT_DIR"
RAW_FILE="${RAW_FILE:-raw_perf_stats.txt}"
XLSX_FILE="${XLSX_FILE:-parsed_perf_stats.xlsx}"
COMBINED_FILE="${COMBINED_FILE:-combined_perf_commands.txt}"
[[ "$RAW_FILE" != /* ]] && RAW_FILE="$OUT_DIR/$RAW_FILE"
[[ "$XLSX_FILE" != /* ]] && XLSX_FILE="$OUT_DIR/$XLSX_FILE"
[[ "$COMBINED_FILE" != /* ]] && COMBINED_FILE="$OUT_DIR/$COMBINED_FILE"
if [[ -n "$INPUT_RAW" && "$INPUT_RAW" != /* ]]; then
  INPUT_RAW="$OUT_DIR/$INPUT_RAW"
fi

command -v python3 >/dev/null 2>&1 || { echo "python3 not found" >&2; exit 1; }
python3 - <<'PYCHK' >/dev/null 2>&1 || { echo "python3 module openpyxl is required" >&2; exit 1; }
import openpyxl
PYCHK

WORK_DIR="$(mktemp -d)"
cleanup() {
  local rc=$?
  rm -rf "$WORK_DIR"
  if [[ $KEEP_COMBINED -eq 0 && -f "$COMBINED_FILE" ]]; then
    rm -f "$COMBINED_FILE"
  fi
  exit $rc
}
trap cleanup EXIT

write_combined_commands() {
  : > "$COMBINED_FILE"
  local cmn nodeid wp cpu start_cpu end_cpu watch_dir

  # SN-F per-node bandwidth, no retry-counted write path.
  for cmn in "${SELECTED_CMNS[@]}"; do
    for wp in "${SNF_READ_WP[@]}"; do
      for nodeid in "${SNF_NODEIDS[@]}"; do
        printf 'perf stat -e arm_cmn_%s/watchpoint_down,wp_chn_sel=0,nodeid=%s,bynodeid=1,wp_dev_sel=0,wp_grp=2,wp_val=%s,wp_mask=%s/ -a -- sleep %s\n' \
          "$cmn" "$nodeid" "$wp" "$SNF_WP_MASK" "$SLEEP_SECS" >> "$COMBINED_FILE"
      done
    done
    for wp in "${SNF_WRITE_NORETRY_WP[@]}"; do
      for nodeid in "${SNF_NODEIDS[@]}"; do
        printf 'perf stat -e arm_cmn_%s/watchpoint_down,wp_chn_sel=0,nodeid=%s,bynodeid=1,wp_dev_sel=0,wp_grp=2,wp_val=%s,wp_mask=%s/ -a -- sleep %s\n' \
          "$cmn" "$nodeid" "$wp" "$SNF_WP_MASK" "$SLEEP_SECS" >> "$COMBINED_FILE"
      done
    done
  done

  # HNS MC SN request/retry counters from the original script.
  # These are separate from the SN-F no-retry watchpoints above.
  # Each req/retry pair is collected in one perf command so they share elapsed time.
  for cmn in "${SELECTED_CMNS[@]}"; do
    printf 'perf stat -e arm_cmn_%s/hns_mc_reqs_local_sn/ -e arm_cmn_%s/hns_mc_retries_local_sn/ -a -- sleep %s\n' \
      "$cmn" "$cmn" "$SLEEP_SECS" >> "$COMBINED_FILE"
    printf 'perf stat -e arm_cmn_%s/hns_mc_reqs_remote_sn/ -e arm_cmn_%s/hns_mc_retries_remote_sn/ -a -- sleep %s\n' \
      "$cmn" "$cmn" "$SLEEP_SECS" >> "$COMBINED_FILE"
  done


  # CCG C2C bandwidth. Keep this independent of RNF.
  # watchpoint_up gives directional C2C totals: CMN0->CMN1 and CMN1->CMN0.
  # watchpoint_down is also collected for node-level inspection.
  for cmn in "${SELECTED_CMNS[@]}"; do
    for watch_dir in watchpoint_up watchpoint_down; do
      for wp in "${CCG_READ_WP[@]}" "${CCG_WRITE_CLEAN_WP[@]}" "${CCG_WRITE_DIRTY_WP[@]}"; do
        for nodeid in "${CCG_NODEIDS[@]}"; do
          printf 'perf stat -a -e arm_cmn_%s/%s,wp_chn_sel=0,nodeid=%s,bynodeid=1,wp_dev_sel=1,wp_grp=2,wp_val=%s,wp_mask=%s/ -- sleep %s\n' \
            "$cmn" "$watch_dir" "$nodeid" "$wp" "$CCG_WP_MASK" "$SLEEP_SECS" >> "$COMBINED_FILE"
        done
      done
    done
  done

  # CPU PMU: per-core events. 0x60 = read, 0x61 = write.
  # Formula in parser: count * 32 / elapsed_time.
  for cmn in "${SELECTED_CMNS[@]}"; do
    if [[ "$cmn" == "0" ]]; then
      start_cpu=0; end_cpu=63
    else
      start_cpu=64; end_cpu=127
    fi
    for cpu in $(seq "$start_cpu" "$end_cpu"); do
      printf 'perf stat -C %s -e armv8_pmuv3_0/event=0x60/ -e armv8_pmuv3_0/event=0x61/ -- sleep %s\n' \
        "$cpu" "$SLEEP_SECS" >> "$COMBINED_FILE"
    done
  done
}

run_perf_commands() {
  : > "$RAW_FILE"
  {
    echo "=== PERF STAT RAW OUTPUT BEGIN ==="
    echo "START_TIME: $(date -Is)"
    echo "HOST: $(hostname)"
    echo "CMN_INDICES: $CMN_INDICES"
    echo "COMBINED_FILE: $COMBINED_FILE"
    echo
  } >> "$RAW_FILE"

  local idx=0
  local cmd
  while IFS= read -r cmd || [[ -n "$cmd" ]]; do
    [[ -z "${cmd//[[:space:]]/}" ]] && continue
    idx=$((idx + 1))
    {
      echo "--- PERF_CMD_BEGIN $idx ---"
      echo "COMMAND: $cmd"
    } >> "$RAW_FILE"

    set +e
    bash -lc "$cmd" >> "$RAW_FILE" 2>&1
    rc=$?
    set -e

    {
      echo "EXIT_STATUS: $rc"
      echo "--- PERF_CMD_END $idx ---"
      echo
    } >> "$RAW_FILE"
  done < "$COMBINED_FILE"

  {
    echo "END_TIME: $(date -Is)"
    echo "=== PERF STAT RAW OUTPUT END ==="
  } >> "$RAW_FILE"
}

parse_raw_to_excel() {
  local raw_in="$1"
  python3 - "$raw_in" "$XLSX_FILE" "$CMN_INDICES" <<'PYCODE'
import re
import sys
from pathlib import Path
from collections import defaultdict
from statistics import mean
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill
from openpyxl.utils import get_column_letter

raw_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])
selected_cmns = [x.strip() for x in sys.argv[3].split(',') if x.strip()]
CMNS = [f'arm_cmn_{x}' for x in selected_cmns]
CPU_RANGES = {'arm_cmn_0': range(0, 64), 'arm_cmn_1': range(64, 128)}
SNF_NODEIDS = ['0x8','0x10','0x18','0x20','0x28','0x30','0x408','0x410','0x418','0x420','0x428','0x430']
SNF_READ_WP = ['0x800002000']
SNF_WRITE_WP = ['0x80000e800']
SNF_NODESET = set(SNF_NODEIDS)
CCG_NODEIDS = ['0x0','0x80','0x100','0x180','0x280','0x300','0x380','0x400']
CCG_NODESET = set(CCG_NODEIDS)
CCG_READ_WP = ['0x800013000']
CCG_WRITE_CLEAN_WP = ['0x800003800','0x80000d800','0x80000b800','0x80000c800']
CCG_WRITE_DIRTY_WP = ['0x80000a800','0x800021000']
CCG_ALL_WP = CCG_READ_WP + CCG_WRITE_CLEAN_WP + CCG_WRITE_DIRTY_WP

cmd_begin_re = re.compile(r'^--- PERF_CMD_BEGIN\s+(\d+)\s+---')
cmd_end_re = re.compile(r'^--- PERF_CMD_END\s+(\d+)\s+---')
command_re = re.compile(r'^COMMAND:\s*(.*)$')
exit_re = re.compile(r'^EXIT_STATUS:\s*(\S+)')
time_re = re.compile(r'^\s*([0-9]*\.?[0-9]+)\s+seconds\s+time\s+elapsed', re.IGNORECASE)
count_re = re.compile(r'^\s*([0-9][0-9,]*)\s+(.+)$')
watch_cmd_re = re.compile(r'arm_cmn_([01])/(watchpoint_up|watchpoint_down),.*?nodeid=(0x[0-9a-fA-F]+).*?wp_dev_sel=([0-9]+).*?wp_grp=([0-9]+).*?wp_val=(0x[0-9a-fA-F]+)', re.IGNORECASE)
cpu_id_re = re.compile(r'(?:^|\s)-C\s*([0-9]+)(?:\s|$)')
cpu_event_re = re.compile(r'armv8_pmuv3_0/event=0x(60|61)/', re.IGNORECASE)
mc_cmd_re = re.compile(r'arm_cmn_([01])/hns_mc_reqs_(local|remote)_sn/.*arm_cmn_[01]/hns_mc_retries_\2_sn/', re.IGNORECASE)
mc_event_re = re.compile(r'arm_cmn_[01]/(hns_mc_reqs_(?:local|remote)_sn|hns_mc_retries_(?:local|remote)_sn)/', re.IGNORECASE)

def normalize_count(token):
    try:
        return int(token.replace(',', ''))
    except Exception:
        return None

def classify_cpu(command):
    if 'armv8_pmuv3_0/event=0x60/' not in command and 'armv8_pmuv3_0/event=0x61/' not in command:
        return None
    m = cpu_id_re.search(command)
    if not m:
        return None
    cpu = int(m.group(1))
    cmn = 'arm_cmn_0' if cpu < 64 else 'arm_cmn_1'
    if cmn not in CMNS:
        return None
    return {'category':'CPU_PMU','cmn':cmn,'direction':'core','nodeid':str(cpu),'wp_val':'event=0x60,event=0x61','command':command}

def classify_watch(command):
    m = watch_cmd_re.search(command)
    if not m:
        return None
    cmn_idx, watch_dir, nodeid, wp_dev_sel, wp_grp, wp_val = m.groups()
    cmn = f'arm_cmn_{cmn_idx}'
    nodeid = nodeid.lower()
    wp_val = wp_val.lower()
    if cmn not in CMNS:
        return None
    watch_dir_l = watch_dir.lower()
    if watch_dir_l == 'watchpoint_down' and wp_dev_sel == '0' and wp_grp == '2' and nodeid in SNF_NODESET:
        if wp_val in SNF_READ_WP:
            direction = 'read'
        elif wp_val in SNF_WRITE_WP:
            direction = 'write'
        else:
            return None
        return {'category':'SNF','cmn':cmn,'direction':direction,'nodeid':nodeid,'wp_val':wp_val,'command':command}
    if wp_dev_sel == '1' and wp_grp == '2' and nodeid in CCG_NODESET and wp_val in CCG_ALL_WP:
        if wp_val in CCG_READ_WP:
            direction = 'read'
        elif wp_val in CCG_WRITE_CLEAN_WP:
            direction = 'write_clean'
        else:
            direction = 'write_dirty'
        return {'category':'CCG','cmn':cmn,'direction':direction,'watch_dir':watch_dir_l,'nodeid':nodeid,'wp_val':wp_val,'command':command}
    return None

def classify_mc(command):
    m = mc_cmd_re.search(command)
    if not m:
        return None
    cmn = f'arm_cmn_{m.group(1)}'
    locality = m.group(2).lower()
    if cmn not in CMNS:
        return None
    return {'category':'SNF_MC','cmn':cmn,'direction':f'{locality}_sn','nodeid':'','wp_val':f'hns_mc_reqs_{locality}_sn,hns_mc_retries_{locality}_sn','command':command}

def parse_block(lines):
    command = ''
    status = 'done'
    time_s = None
    counts = []
    for line in lines:
        m = command_re.match(line)
        if m:
            command = m.group(1).strip(); continue
        m = exit_re.match(line)
        if m:
            status = 'OK' if m.group(1) == '0' else f'EXIT_{m.group(1)}'; continue
        m = time_re.search(line)
        if m:
            time_s = float(m.group(1)); continue
        m = count_re.match(line)
        if m:
            count = normalize_count(m.group(1))
            if count is not None:
                counts.append((count, m.group(2)))
    if not command or time_s is None:
        return []
    out = []
    base = classify_cpu(command)
    if base:
        for count, event_text in counts:
            em = cpu_event_re.search(event_text)
            if not em:
                continue
            event_name = 'event_0x' + em.group(1).lower()
            rec = dict(base)
            rec.update({'direction':'read' if event_name == 'event_0x60' else 'write','wp_val':event_name,'count':count,'time_s':time_s,'status':status})
            out.append(rec)
        return out
    base = classify_mc(command)
    if base:
        for count, event_text in counts:
            em = mc_event_re.search(event_text)
            if not em:
                continue
            event_name = em.group(1).lower()
            rec = dict(base)
            rec.update({'wp_val':event_name,'count':count,'time_s':time_s,'status':status})
            out.append(rec)
        return out
    base = classify_watch(command)
    if base and counts:
        rec = dict(base)
        rec.update({'count':counts[0][0], 'time_s':time_s, 'status':status})
        out.append(rec)
    return out

records = []
block = []
in_block = False
with raw_path.open('r', encoding='utf-8', errors='replace') as f:
    for raw_line in f:
        line = raw_line.rstrip('\n')
        if cmd_begin_re.match(line):
            block = [line]
            in_block = True
            continue
        if in_block:
            block.append(line)
            if cmd_end_re.match(line):
                records.extend(parse_block(block))
                block = []
                in_block = False
if in_block and block:
    records.extend(parse_block(block))

for r in records:
    bytes_per_count = 32 if r['category'] == 'CPU_PMU' else 64
    r['bytes'] = (r['count'] or 0) * bytes_per_count
    r['bw_gbps'] = r['bytes'] / r['time_s'] / 1_000_000_000 if r.get('time_s') else 0.0

agg = defaultdict(lambda: {'counts': defaultdict(int), 'times': defaultdict(list)})
for r in records:
    key = (r['category'], r['cmn'], r['nodeid'], r['direction'])
    agg[key]['counts'][r['wp_val']] += r['count'] or 0
    agg[key]['times'][r['wp_val']].append(r['time_s'])

def avg_time_for(entry, wp_list):
    vals = []
    for wp in wp_list:
        vals.extend(entry['times'].get(wp, []))
    return mean(vals) if vals else None

def total_count(entry, wp_list):
    return sum(entry['counts'].get(wp, 0) for wp in wp_list)

summary = {'CPU': defaultdict(lambda: {'read':0.0,'write':0.0}), 'SNF': defaultdict(lambda: {'read':0.0,'write':0.0}), 'SNF_MC': defaultdict(lambda: {'reqs':0,'retries':0,'total':0.0,'retry':0.0,'net':0.0,'retry_ratio':0.0}), 'CCG': defaultdict(lambda: {'up_read':0.0,'up_write_clean':0.0,'up_write_dirty':0.0,'down_read':0.0,'down_write_clean':0.0,'down_write_dirty':0.0})}
wb = Workbook()
header_fill = PatternFill('solid', fgColor='1F4E78')
section_fill = PatternFill('solid', fgColor='D9EAF7')
total_fill = PatternFill('solid', fgColor='FFF2CC')
header_font = Font(color='FFFFFF', bold=True)
bold_font = Font(bold=True)

def style_header(ws):
    for c in ws[1]:
        c.fill = header_fill
        c.font = header_font

ws_raw = wb.active
ws_raw.title = 'RawData'
ws_raw.append(['Category','CMN','Direction','NodeID','Watchpoint','Count','TimeElapsed_s','Bytes','BW_GBps','Status','Command'])
style_header(ws_raw)
for r in records:
    ws_raw.append([r['category'],r['cmn'],r['direction'],r['nodeid'],r['wp_val'],r['count'],r['time_s'],r['bytes'],r['bw_gbps'],r['status'],r['command']])
for i,w in enumerate([12,12,12,12,22,14,16,14,14,12,90],1):
    ws_raw.column_dimensions[get_column_letter(i)].width = w

ws_cpu = wb.create_sheet('CPU_PMU')
ws_cpu.append(['CMN','CPU','ReadCount_0x60','ReadTime_s','ReadBytes','CPUReadBW_GBps','WriteCount_0x61','WriteTime_s','WriteBytes','CPUWriteBW_GBps'])
style_header(ws_cpu)
for cmn in CMNS:
    ws_cpu.append([f'CPU PMU - {cmn}'])
    for cell in ws_cpu[ws_cpu.max_row]:
        cell.fill = section_fill; cell.font = bold_font
    total_read = total_write = 0.0
    for cpu in CPU_RANGES[cmn]:
        cpu_str = str(cpu)
        read_entry = agg.get(('CPU_PMU', cmn, cpu_str, 'read'), {'counts':{}, 'times':{}})
        write_entry = agg.get(('CPU_PMU', cmn, cpu_str, 'write'), {'counts':{}, 'times':{}})
        read_count = read_entry['counts'].get('event_0x60', 0)
        write_count = write_entry['counts'].get('event_0x61', 0)
        read_time = avg_time_for(read_entry, ['event_0x60'])
        write_time = avg_time_for(write_entry, ['event_0x61'])
        read_bw = read_count * 32 / read_time / 1_000_000_000 if read_time else 0.0
        write_bw = write_count * 32 / write_time / 1_000_000_000 if write_time else 0.0
        total_read += read_bw; total_write += write_bw
        ws_cpu.append([cmn,cpu,read_count,read_time,read_count * 32,read_bw,write_count,write_time,write_count * 32,write_bw])
    summary['CPU'][cmn]['read'] = total_read
    summary['CPU'][cmn]['write'] = total_write
    ws_cpu.append([cmn,'Total CPU Read BW','','','',total_read,'','','',''])
    for cell in ws_cpu[ws_cpu.max_row]: cell.fill = total_fill; cell.font = bold_font
    ws_cpu.append([cmn,'Total CPU Write BW','','','','','','','',total_write])
    for cell in ws_cpu[ws_cpu.max_row]: cell.fill = total_fill; cell.font = bold_font
    ws_cpu.append([])
for i,w in enumerate([14,10,18,14,16,18,18,14,16,18],1):
    ws_cpu.column_dimensions[get_column_letter(i)].width = w

ws_snf = wb.create_sheet('SNF_NoRetry')
ws_snf.append(['CMN','NodeID','ReadCount_0x800002000','ReadTime_s','ReadBW_GBps','WriteNoRetryCount_0x80000e800','WriteNoRetryTime_s','WriteNoRetryBW_GBps'])
style_header(ws_snf)
for cmn in CMNS:
    ws_snf.append([f'SNF no-retry - {cmn}'])
    for cell in ws_snf[ws_snf.max_row]: cell.fill = section_fill; cell.font = bold_font
    for nodeid in SNF_NODEIDS:
        read_entry = agg.get(('SNF', cmn, nodeid, 'read'), {'counts':{}, 'times':{}})
        write_entry = agg.get(('SNF', cmn, nodeid, 'write'), {'counts':{}, 'times':{}})
        read_count = total_count(read_entry, SNF_READ_WP)
        write_count = total_count(write_entry, SNF_WRITE_WP)
        read_time = avg_time_for(read_entry, SNF_READ_WP)
        write_time = avg_time_for(write_entry, SNF_WRITE_WP)
        read_bw = read_count * 64 / read_time / 1_000_000_000 if read_time else 0.0
        write_bw = write_count * 64 / write_time / 1_000_000_000 if write_time else 0.0
        summary['SNF'][cmn]['read'] += read_bw
        summary['SNF'][cmn]['write'] += write_bw
        ws_snf.append([cmn,nodeid,read_count,read_time,read_bw,write_count,write_time,write_bw])
    ws_snf.append([f'Total SNF Read BW no-retry path ({cmn})','','','',summary['SNF'][cmn]['read'],'','',''])
    for cell in ws_snf[ws_snf.max_row]: cell.fill = total_fill; cell.font = bold_font
    ws_snf.append([f'Total SNF Write BW no-retry path ({cmn})','','','','','','',summary['SNF'][cmn]['write']])
    for cell in ws_snf[ws_snf.max_row]: cell.fill = total_fill; cell.font = bold_font
    ws_snf.append([])
for i,w in enumerate([14,12,22,14,14,28,18,22],1):
    ws_snf.column_dimensions[get_column_letter(i)].width = w


def snf_mc_component(cmn, locality):
    req_name = f'hns_mc_reqs_{locality}_sn'
    retry_name = f'hns_mc_retries_{locality}_sn'
    entry = agg.get(('SNF_MC', cmn, '', f'{locality}_sn'), {'counts':{}, 'times':{}})
    reqs = entry['counts'].get(req_name, 0)
    retries = entry['counts'].get(retry_name, 0)
    time_s = avg_time_for(entry, [req_name]) or avg_time_for(entry, [retry_name])
    total_bw = reqs * 64 / time_s / 1_000_000_000 if time_s else 0.0
    retry_bw = retries * 64 / time_s / 1_000_000_000 if time_s else 0.0
    net_bw = max(reqs - retries, 0) * 64 / time_s / 1_000_000_000 if time_s else 0.0
    return reqs, retries, time_s, total_bw, retry_bw, net_bw

ws_mc = wb.create_sheet('SNF_MC')
ws_mc.append(['CMN','LocalReqs_Count','LocalRetries_Count','LocalTime_s','LocalTotalBW_GBps','LocalRetryBW_GBps','LocalEffectiveBW_GBps','RemoteReqs_Count','RemoteRetries_Count','RemoteTime_s','RemoteTotalBW_GBps','RemoteRetryBW_GBps','RemoteEffectiveBW_GBps','ReqsTotal_Count','RetriesTotal_Count','TotalBW_InclRetries_GBps','RetryBW_GBps','EffectiveBW_ExclRetries_GBps','RetryRatio_pct'])
style_header(ws_mc)
for cmn in CMNS:
    l_reqs,l_ret,l_time,l_total,l_retry,l_net = snf_mc_component(cmn, 'local')
    r_reqs,r_ret,r_time,r_total,r_retry,r_net = snf_mc_component(cmn, 'remote')
    reqs = l_reqs + r_reqs
    retries = l_ret + r_ret
    total_bw = l_total + r_total
    retry_bw = l_retry + r_retry
    net_bw = l_net + r_net
    retry_ratio = retry_bw / total_bw * 100.0 if total_bw else 0.0
    summary['SNF_MC'][cmn]['reqs'] = reqs
    summary['SNF_MC'][cmn]['retries'] = retries
    summary['SNF_MC'][cmn]['total'] = total_bw
    summary['SNF_MC'][cmn]['retry'] = retry_bw
    summary['SNF_MC'][cmn]['net'] = net_bw
    summary['SNF_MC'][cmn]['retry_ratio'] = retry_ratio
    ws_mc.append([cmn,l_reqs,l_ret,l_time,l_total,l_retry,l_net,r_reqs,r_ret,r_time,r_total,r_retry,r_net,reqs,retries,total_bw,retry_bw,net_bw,retry_ratio])
for i,w in enumerate([14,18,18,14,20,18,22,18,18,14,20,18,24,18,18,24,18,28,16],1):
    ws_mc.column_dimensions[get_column_letter(i)].width = w


ws_ccg = wb.create_sheet('CCG_C2C')
ws_ccg.append(['CMN','Direction','NodeID','ReadCount','ReadTime_s','ReadBW_GBps','WriteCleanCount','WriteCleanTime_s','WriteCleanBW_GBps','WriteDirtyCount','WriteDirtyTime_s','WriteDirtyBW_GBps','WriteTotalBW_GBps'])
style_header(ws_ccg)
for cmn in CMNS:
    for watch_dir in ['watchpoint_up', 'watchpoint_down']:
        label = 'up' if watch_dir == 'watchpoint_up' else 'down'
        ws_ccg.append([f'CCG C2C {label} - {cmn}'])
        for cell in ws_ccg[ws_ccg.max_row]: cell.fill = section_fill; cell.font = bold_font
        for nodeid in CCG_NODEIDS:
            read_entry = agg.get(('CCG', cmn, nodeid, 'read'), {'counts':{}, 'times':{}})
            wc_entry = agg.get(('CCG', cmn, nodeid, 'write_clean'), {'counts':{}, 'times':{}})
            wd_entry = agg.get(('CCG', cmn, nodeid, 'write_dirty'), {'counts':{}, 'times':{}})
            # Separate up/down by filtering raw records because agg key intentionally groups by category/direction.
            def sum_for(wps, direction):
                total = 0
                times = []
                for r in records:
                    if r['category'] == 'CCG' and r['cmn'] == cmn and r['nodeid'] == nodeid and r.get('watch_dir') == watch_dir and r['wp_val'] in wps and r['direction'] == direction:
                        total += r['count'] or 0
                        if r.get('time_s'): times.append(r['time_s'])
                return total, (mean(times) if times else None)
            read_count, read_time = sum_for(CCG_READ_WP, 'read')
            wc_count, wc_time = sum_for(CCG_WRITE_CLEAN_WP, 'write_clean')
            wd_count, wd_time = sum_for(CCG_WRITE_DIRTY_WP, 'write_dirty')
            read_bw = read_count * 64 / read_time / 1_000_000_000 if read_time else 0.0
            wc_bw = wc_count * 64 / wc_time / 1_000_000_000 if wc_time else 0.0
            wd_bw = wd_count * 64 / wd_time / 1_000_000_000 if wd_time else 0.0
            summary['CCG'][cmn][f'{label}_read'] += read_bw
            summary['CCG'][cmn][f'{label}_write_clean'] += wc_bw
            summary['CCG'][cmn][f'{label}_write_dirty'] += wd_bw
            ws_ccg.append([cmn,label,nodeid,read_count,read_time,read_bw,wc_count,wc_time,wc_bw,wd_count,wd_time,wd_bw,wc_bw+wd_bw])
        ws_ccg.append([f'Total CCG {label} Read BW ({cmn})','','','','',summary['CCG'][cmn][f'{label}_read'],'','','','','','',''])
        for cell in ws_ccg[ws_ccg.max_row]: cell.fill = total_fill; cell.font = bold_font
        ws_ccg.append([f'Total CCG {label} Write BW ({cmn})','','','','','','','','','','','',summary['CCG'][cmn][f'{label}_write_clean'] + summary['CCG'][cmn][f'{label}_write_dirty']])
        for cell in ws_ccg[ws_ccg.max_row]: cell.fill = total_fill; cell.font = bold_font
        ws_ccg.append([])
for i,w in enumerate([14,12,10,14,14,14,18,16,18,18,16,18,18],1):
    ws_ccg.column_dimensions[get_column_letter(i)].width = w

ws_summary = wb.create_sheet('Summary')
ws_summary.append(['Chiplet','Metric','Value','Unit'])
style_header(ws_summary)
for cmn in CMNS:
    chip_name = f'Chiplet {cmn[-1]}'
    for row in [
        (chip_name, f'CPU PMU Total Read BW 0x60 ({cmn})', summary['CPU'][cmn]['read'], 'GBps'),
        (chip_name, f'CPU PMU Total Write BW 0x61 ({cmn})', summary['CPU'][cmn]['write'], 'GBps'),
        (chip_name, f'SNF Total Read BW no-retry path ({cmn})', summary['SNF'][cmn]['read'], 'GBps'),
        (chip_name, f'SNF Total Write BW no-retry path ({cmn})', summary['SNF'][cmn]['write'], 'GBps'),
        (chip_name, f'SNF MC Total BW incl retries ({cmn})', summary['SNF_MC'][cmn]['total'], 'GBps'),
        (chip_name, f'HNS MC Retry BW local+remote ({cmn})', summary['SNF_MC'][cmn]['retry'], 'GBps'),
        (chip_name, f'SNF MC Effective BW excl retries ({cmn})', summary['SNF_MC'][cmn]['net'], 'GBps'),
        (chip_name, f'SNF MC Retry Ratio ({cmn})', summary['SNF_MC'][cmn]['retry_ratio'], '%'),
        (chip_name, f'CCG Up Read BW ({cmn})', summary['CCG'][cmn]['up_read'], 'GBps'),
        (chip_name, f'CCG Up Write BW ({cmn})', summary['CCG'][cmn]['up_write_clean'] + summary['CCG'][cmn]['up_write_dirty'], 'GBps'),
        (chip_name, f'CCG Down Read BW ({cmn})', summary['CCG'][cmn]['down_read'], 'GBps'),
        (chip_name, f'CCG Down Write BW ({cmn})', summary['CCG'][cmn]['down_write_clean'] + summary['CCG'][cmn]['down_write_dirty'], 'GBps')]:
        ws_summary.append(row)
    ws_summary.append([])
ws_summary.column_dimensions['A'].width = 14
ws_summary.column_dimensions['B'].width = 48
ws_summary.column_dimensions['C'].width = 16
ws_summary.column_dimensions['D'].width = 10

for ws in wb.worksheets:
    ws.freeze_panes = 'A2'
out_path.parent.mkdir(parents=True, exist_ok=True)
wb.save(out_path)

for cmn in CMNS:
    print(f'=== {cmn} ===')
    print(f'CPU PMU Total Read BW 0x60:        {summary["CPU"][cmn]["read"]:.6f} GBps')
    print(f'CPU PMU Total Write BW 0x61:       {summary["CPU"][cmn]["write"]:.6f} GBps')
    print(f'SNF Total Read BW no-retry path:   {summary["SNF"][cmn]["read"]:.6f} GBps')
    print(f'SNF Total Write BW no-retry path:  {summary["SNF"][cmn]["write"]:.6f} GBps')
    print(f'SNF MC Retry Ratio:                {summary["SNF_MC"][cmn]["retry_ratio"]:.2f}%')
    print(f'CCG Up Read BW:                    {summary["CCG"][cmn]["up_read"]:.6f} GBps')
    print(f'CCG Up Write BW:                   {(summary["CCG"][cmn]["up_write_clean"] + summary["CCG"][cmn]["up_write_dirty"]):.6f} GBps')
    print(f'CCG Down Read BW:                  {summary["CCG"][cmn]["down_read"]:.6f} GBps')
    print(f'CCG Down Write BW:                 {(summary["CCG"][cmn]["down_write_clean"] + summary["CCG"][cmn]["down_write_dirty"]):.6f} GBps')
PYCODE
}

write_combined_commands

if [[ $PARSE_ONLY -eq 1 ]]; then
  parse_raw_to_excel "$INPUT_RAW"
  printf 'Output files:
  Raw:   %s
  Excel: %s
' "$INPUT_RAW" "$XLSX_FILE"
  exit 0
fi

run_perf_commands

if [[ $RUN_ONLY -eq 1 ]]; then
  echo "Raw perf output: $RAW_FILE"
  echo "Combined commands: $COMBINED_FILE"
  exit 0
fi

parse_raw_to_excel "$RAW_FILE"
printf 'Output files:
  Raw:   %s
  Excel: %s
' "$RAW_FILE" "$XLSX_FILE"
