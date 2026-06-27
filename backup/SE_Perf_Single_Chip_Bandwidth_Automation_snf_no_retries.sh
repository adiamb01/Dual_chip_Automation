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
# Single-chip version: only arm_cmn_0 is generated and parsed.

RNF_NODEIDS=(
  0x88 0x90 0x98 0xa0 0xa8 0x108 0x110 0x118 0x120 0x128
  0x188 0x190 0x198 0x1a0 0x1a8 0x208 0x210 0x218 0x220 0x228
  0x288 0x290 0x298 0x2a0 0x2a8 0x308 0x310 0x318 0x320 0x328
  0x388 0x390 0x398 0x3a0 0x3a8
)
SNF_NODEIDS=(
  0x8 0x10 0x18 0x20 0x28 0x30 0x408 0x410 0x418 0x420 0x428 0x430
)
CCG_NODEIDS=(
  0x0 0x80 0x100 0x180 0x280 0x300 0x380 0x400
)
RNF_READ_WP=(0x4c0000000 0xe0000000)
RNF_WRITE_WP=(0x2a0000000 0x840000000 0x360000000 0x2e0000000 0x320000000)
SNF_READ_WP=(0x80000000 0x220000000)
SNF_WRITE_WP=(0x3a0000000)
CCG_WP=0x740000000

usage() {
  cat <<'USAGE'
Usage:
  ./single_chip_automation.sh [options]

Options:
  --out-dir DIR          Output directory. Default: current directory
  --raw FILE             Raw output file. Default: <out-dir>/raw_perf_stats.txt
  --xlsx FILE            Excel workbook. Default: <out-dir>/parsed_perf_stats.xlsx
  --combined FILE        Combined commands file. Default: <out-dir>/combined_perf_commands.txt
  --sleep SECS           Sleep duration per perf command. Default: 0.2
  --parse-only FILE      Skip perf execution and only parse an existing raw file
  --run-only             Only generate combined commands and raw output; skip Excel parsing
  --no-combined          Do not keep combined command file on disk
  -h, --help             Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)
      OUT_DIR="$2"; shift 2 ;;
    --raw)
      RAW_FILE="$2"; shift 2 ;;
    --xlsx)
      XLSX_FILE="$2"; shift 2 ;;
    --combined)
      COMBINED_FILE="$2"; shift 2 ;;
    --sleep)
      SLEEP_SECS="$2"; shift 2 ;;
    --parse-only)
      PARSE_ONLY=1; INPUT_RAW="$2"; shift 2 ;;
    --run-only)
      RUN_ONLY=1; shift ;;
    --no-combined)
      KEEP_COMBINED=0; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1 ;;
  esac
done

mkdir -p "$OUT_DIR"
RAW_FILE="${RAW_FILE:-$OUT_DIR/raw_perf_stats.txt}"
XLSX_FILE="${XLSX_FILE:-$OUT_DIR/parsed_perf_stats.xlsx}"
COMBINED_FILE="${COMBINED_FILE:-$OUT_DIR/combined_perf_commands.txt}"
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

  local cmn nodeid wp

  # RNF: watchpoint_up, wp_dev_sel=1
  for cmn in 0; do
    for wp in "${RNF_READ_WP[@]}"; do
      for nodeid in "${RNF_NODEIDS[@]}"; do
        printf 'perf stat -e arm_cmn_%s/watchpoint_up,wp_chn_sel=0,nodeid=%s,bynodeid=1,wp_dev_sel=1,wp_grp=0,wp_val=%s,wp_mask=0xfffffff01fffffff/ -a -- sleep %s\n' \
          "$cmn" "$nodeid" "$wp" "$SLEEP_SECS" >> "$COMBINED_FILE"
      done
    done
    for wp in "${RNF_WRITE_WP[@]}"; do
      for nodeid in "${RNF_NODEIDS[@]}"; do
        printf 'perf stat -e arm_cmn_%s/watchpoint_up,wp_chn_sel=0,nodeid=%s,bynodeid=1,wp_dev_sel=1,wp_grp=0,wp_val=%s,wp_mask=0xfffffff01fffffff/ -a -- sleep %s\n' \
          "$cmn" "$nodeid" "$wp" "$SLEEP_SECS" >> "$COMBINED_FILE"
      done
    done
  done

  # CPU PMU: per-core events. 0x60 = read, 0x61 = write.
  # Formula in parser: count * 32 / elapsed_time.
  local cpu
  for cpu in $(seq 0 63); do
    printf 'perf stat -C %s -e armv8_pmuv3_0/event=0x60/ -e armv8_pmuv3_0/event=0x61/ -- sleep %s\n' \
      "$cpu" "$SLEEP_SECS" >> "$COMBINED_FILE"
  done

  # SNF effective bandwidth from HNS MC counters.
  # Formula: ((hns_mc_reqs_local_sn - hns_mc_retries_local_sn) * 64) / elapsed_time.
  # These two events are collected in the same perf command so they share one elapsed time.
  printf 'perf stat -e arm_cmn_0/hns_mc_reqs_local_sn/ -e arm_cmn_0/hns_mc_retries_local_sn/ -a -- sleep %s\n' \
    "$SLEEP_SECS" >> "$COMBINED_FILE"

  # CCG: watchpoint_up and watchpoint_down, wp_dev_sel=1, exclusive
  for cmn in 0; do
    for nodeid in "${CCG_NODEIDS[@]}"; do
      printf 'perf stat -e arm_cmn_%s/watchpoint_up,wp_chn_sel=0,nodeid=%s,bynodeid=1,wp_dev_sel=1,wp_grp=0,wp_val=%s,wp_mask=0x0,wp_exclusive=1/ -a -- sleep %s\n' \
        "$cmn" "$nodeid" "$CCG_WP" "$SLEEP_SECS" >> "$COMBINED_FILE"
    done
    for nodeid in "${CCG_NODEIDS[@]}"; do
      printf 'perf stat -e arm_cmn_%s/watchpoint_down,wp_chn_sel=0,nodeid=%s,bynodeid=1,wp_dev_sel=1,wp_grp=0,wp_val=%s,wp_mask=0x0,wp_exclusive=1/ -a -- sleep %s\n' \
        "$cmn" "$nodeid" "$CCG_WP" "$SLEEP_SECS" >> "$COMBINED_FILE"
    done
  done
}
run_perf_commands() {
  : > "$RAW_FILE"
  {
    echo "=== PERF STAT RAW OUTPUT BEGIN ==="
    echo "START_TIME: $(date -Is)"
    echo "HOST: $(hostname)"
    echo "COMBINED_FILE: $COMBINED_FILE"
    echo
  } >> "$RAW_FILE"

  local idx=0
  local cmd
  while IFS= read -r cmd || [[ -n "$cmd" ]]; do
    [[ -z "${cmd//[[:space:]]/}" ]] && continue
    idx=$((idx + 1))
    #echo "[$(date '+%F %T')] Running command $idx" >&2
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
  python3 - "$raw_in" "$XLSX_FILE" <<'PY'
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
CMNS = ['arm_cmn_0']

RNF_NODEIDS = [
    '0x88','0x90','0x98','0xa0','0xa8','0x108','0x110','0x118','0x120','0x128',
    '0x188','0x190','0x198','0x1a0','0x1a8','0x208','0x210','0x218','0x220','0x228',
    '0x288','0x290','0x298','0x2a0','0x2a8','0x308','0x310','0x318','0x320','0x328',
    '0x388','0x390','0x398','0x3a0','0x3a8'
]
SNF_NODEIDS = ['0x8','0x10','0x18','0x20','0x28','0x30','0x408','0x410','0x418','0x420','0x428','0x430']
CCG_NODEIDS = ['0x0','0x80','0x100','0x180','0x280','0x300','0x380','0x400']
RNF_READ_WP = ['0x4c0000000', '0xe0000000']
RNF_WRITE_WP = ['0x2a0000000', '0x840000000', '0x360000000', '0x2e0000000', '0x320000000']
SNF_READ_WP = ['0x80000000', '0x220000000']
SNF_WRITE_WP = ['0x3a0000000']
SNF_ALL_WP = SNF_READ_WP + SNF_WRITE_WP
CCG_WP = ['0x740000000']
RNF_NODESET = set(RNF_NODEIDS)
SNF_NODESET = set(SNF_NODEIDS)
CCG_NODESET = set(CCG_NODEIDS)

watch_cmd_re = re.compile(r'COMMAND:\s*perf\s+stat\s+-e\s+(arm_cmn_0)/(watchpoint_up|watchpoint_down),.*?nodeid=(0x[0-9a-fA-F]+).*?wp_val=(0x[0-9a-fA-F]+)', re.IGNORECASE)
mc_cmd_re = re.compile(r'COMMAND:\s*perf\s+stat\s+-e\s+(arm_cmn_0)/hns_mc_reqs_local_sn/\s+-e\s+arm_cmn_0/hns_mc_retries_local_sn/', re.IGNORECASE)
cpu_cmd_re = re.compile(r'COMMAND:\s*perf\s+stat\s+-C\s+(\d+)\s+-e\s+armv8_pmuv3_0/event=0x60/\s+-e\s+armv8_pmuv3_0/event=0x61/', re.IGNORECASE)
time_re = re.compile(r'^\s*([0-9]*\.?[0-9]+)\s+seconds\s+time\s+elapsed', re.IGNORECASE)
perf_re = re.compile(r'arm_cmn_0/(?:watchpoint_(?:up|down)|hns_mc_reqs_local_sn|hns_mc_retries_local_sn)|armv8_pmuv3_0/event=0x(?:60|61)/', re.IGNORECASE)
event_re = re.compile(r'arm_cmn_0/(hns_mc_reqs_local_sn|hns_mc_retries_local_sn)/', re.IGNORECASE)
cpu_event_re = re.compile(r'armv8_pmuv3_0/event=0x(60|61)/', re.IGNORECASE)


def normalize_count(token: str):
    token = token.strip().replace(',', '')
    if not token:
        return None
    lower = token.lower()
    if 'not counted' in lower or 'not supported' in lower or '<not' in lower:
        return None
    try:
        return int(float(token))
    except ValueError:
        return None


def classify(nodeid: str, wp_val: str, watch_dir: str):
    nodeid = nodeid.lower()
    wp_val = wp_val.lower()
    watch_dir = watch_dir.lower()
    if nodeid in RNF_NODESET:
        if wp_val in RNF_READ_WP:
            return 'RNF', 'read'
        if wp_val in RNF_WRITE_WP:
            return 'RNF', 'write'
    if nodeid in SNF_NODESET and wp_val in SNF_ALL_WP:
        return 'SNF', 'total'
    if nodeid in CCG_NODESET and wp_val in CCG_WP:
        return 'CCG', 'up' if watch_dir == 'watchpoint_up' else 'down'
    return None, None

records = []
current = None
with raw_path.open('r', encoding='utf-8', errors='replace') as f:
    for raw_line in f:
        line = raw_line.rstrip('\n')
        m = watch_cmd_re.search(line)
        if m:
            cmn, watch_dir, nodeid, wp_val = m.groups()
            category, direction = classify(nodeid, wp_val, watch_dir)
            current = {
                'category': category,
                'cmn': cmn,
                'direction': direction,
                'watch_dir': watch_dir.lower(),
                'nodeid': nodeid.lower(),
                'wp_val': wp_val.lower(),
                'count': None,
                'time_s': None,
                'status': 'done',
                'command': line.split('COMMAND:', 1)[1].strip(),
            }
            continue
        m = mc_cmd_re.search(line)
        if m:
            cmn = m.group(1)
            current = {
                'category': 'SNF_MC',
                'cmn': cmn,
                'direction': 'local_sn',
                'watch_dir': '',
                'nodeid': '',
                'wp_val': 'hns_mc_reqs_local_sn,hns_mc_retries_local_sn',
                'count': None,
                'counts_map': {},
                'time_s': None,
                'status': 'done',
                'command': line.split('COMMAND:', 1)[1].strip(),
            }
            continue
        m = cpu_cmd_re.search(line)
        if m:
            cpu = m.group(1)
            current = {
                'category': 'CPU_PMU',
                'cmn': 'cpu',
                'direction': 'core',
                'watch_dir': '',
                'nodeid': cpu,
                'wp_val': 'event=0x60,event=0x61',
                'count': None,
                'counts_map': {},
                'time_s': None,
                'status': 'done',
                'command': line.split('COMMAND:', 1)[1].strip(),
            }
            continue
        if current is None:
            continue
        if line.startswith('EXIT_STATUS:'):
            rc = line.split(':', 1)[1].strip()
            current['status'] = 'OK' if rc == '0' else f'EXIT_{rc}'
            continue
        if perf_re.search(line):
            first = line.strip().split()[0] if line.strip() else ''
            count = normalize_count(first)
            if count is not None:
                em = event_re.search(line)
                cem = cpu_event_re.search(line)
                if current.get('category') == 'SNF_MC' and em:
                    current.setdefault('counts_map', {})[em.group(1).lower()] = count
                elif current.get('category') == 'CPU_PMU' and cem:
                    current.setdefault('counts_map', {})['event_0x' + cem.group(1).lower()] = count
                else:
                    current['count'] = count
            continue
        tm = time_re.search(line)
        if tm:
            current['time_s'] = float(tm.group(1))
            if current.get('category') == 'SNF_MC':
                for event_name, event_count in current.get('counts_map', {}).items():
                    rec = dict(current)
                    rec.pop('counts_map', None)
                    rec['wp_val'] = event_name
                    rec['count'] = event_count
                    records.append(rec)
            elif current.get('category') == 'CPU_PMU':
                for event_name, event_count in current.get('counts_map', {}).items():
                    rec = dict(current)
                    rec.pop('counts_map', None)
                    rec['wp_val'] = event_name
                    rec['direction'] = 'read' if event_name == 'event_0x60' else 'write'
                    rec['count'] = event_count
                    records.append(rec)
            else:
                records.append(current)
            current = None
if current is not None:
    if current.get('category') == 'SNF_MC':
        for event_name, event_count in current.get('counts_map', {}).items():
            rec = dict(current)
            rec.pop('counts_map', None)
            rec['wp_val'] = event_name
            rec['count'] = event_count
            records.append(rec)
    elif current.get('category') == 'CPU_PMU':
        for event_name, event_count in current.get('counts_map', {}).items():
            rec = dict(current)
            rec.pop('counts_map', None)
            rec['wp_val'] = event_name
            rec['direction'] = 'read' if event_name == 'event_0x60' else 'write'
            rec['count'] = event_count
            records.append(rec)
    else:
        records.append(current)

records = [r for r in records if r['category'] is not None]
for r in records:
    bytes_per_count = 32 if r.get('category') == 'CPU_PMU' else 64
    r['bytes'] = (r['count'] or 0) * bytes_per_count
    r['bw_gbps'] = (r['bytes'] / r['time_s'] / 1_000_000_000) if r['count'] is not None and r['time_s'] else 0.0

agg = defaultdict(lambda: {'counts': defaultdict(int), 'times': defaultdict(list)})
for r in records:
    key = (r['category'], r['cmn'], r['nodeid'], r['direction'])
    agg[key]['counts'][r['wp_val']] += r['count'] or 0
    if r['time_s']:
        agg[key]['times'][r['wp_val']].append(r['time_s'])


def avg_time_for(entry, wp_list):
    vals = []
    for wp in wp_list:
        vals.extend(entry['times'].get(wp, []))
    return mean(vals) if vals else None


def total_count(entry, wp_list):
    return sum(entry['counts'].get(wp, 0) for wp in wp_list)

summary = {
    'RNF': defaultdict(lambda: {'read': 0.0, 'write': 0.0}),
    'CPU': defaultdict(lambda: {'read': 0.0, 'write': 0.0}),
    'SNF': defaultdict(lambda: {'reqs': 0, 'retries': 0, 'total': 0.0, 'retry': 0.0, 'net': 0.0, 'time_s': None, 'retry_ratio': 0.0}),
    'CCG': defaultdict(lambda: {'up': 0.0, 'down': 0.0}),
}

wb = Workbook()
header_fill = PatternFill('solid', fgColor='1F4E78')
section_fill = PatternFill('solid', fgColor='D9EAF7')
total_fill = PatternFill('solid', fgColor='FFF2CC')
header_font = Font(color='FFFFFF', bold=True)
bold_font = Font(bold=True)

ws_raw = wb.active
ws_raw.title = 'RawData'
raw_headers = ['Category','CMN','Direction','NodeID','Watchpoint','Count','TimeElapsed_s','Bytes','BW_GBps','Status','Command']
ws_raw.append(raw_headers)
for c in ws_raw[1]:
    c.fill = header_fill
    c.font = header_font
for r in records:
    ws_raw.append([r['category'], r['cmn'], r['direction'], r['nodeid'], r['wp_val'], r['count'], r['time_s'], r['bytes'], r['bw_gbps'], r['status'], r['command']])
for width_idx, width in enumerate([12,12,12,12,22,14,16,14,14,12,90], start=1):
    ws_raw.column_dimensions[get_column_letter(width_idx)].width = width


def style_header(ws):
    for c in ws[1]:
        c.fill = header_fill
        c.font = header_font


def add_cpu_sheet():
    ws = wb.create_sheet('CPU_PMU')
    headers = ['CPU','ReadCount_0x60','ReadTime_s','CPUReadBW_GBps','WriteCount_0x61','WriteTime_s','CPUWriteBW_GBps']
    ws.append(headers)
    style_header(ws)
    total_read = 0.0
    total_write = 0.0
    for cpu in range(64):
        cpu_str = str(cpu)
        read_entry = agg.get(('CPU_PMU', 'cpu', cpu_str, 'read'), {'counts':{}, 'times':{}})
        write_entry = agg.get(('CPU_PMU', 'cpu', cpu_str, 'write'), {'counts':{}, 'times':{}})
        read_count = read_entry['counts'].get('event_0x60', 0)
        write_count = write_entry['counts'].get('event_0x61', 0)
        read_time = avg_time_for(read_entry, ['event_0x60'])
        write_time = avg_time_for(write_entry, ['event_0x61'])
        read_bw = (read_count * 32 / read_time / 1_000_000_000) if read_time else 0.0
        write_bw = (write_count * 32 / write_time / 1_000_000_000) if write_time else 0.0
        total_read += read_bw
        total_write += write_bw
        ws.append([cpu, read_count, read_time, read_bw, write_count, write_time, write_bw])
    summary['CPU']['cpu']['read'] = total_read
    summary['CPU']['cpu']['write'] = total_write
    ws.append(['Total CPU Read BW', '', '', total_read, '', '', ''])
    for cell in ws[ws.max_row]:
        cell.fill = total_fill
        cell.font = bold_font
    ws.append(['Total CPU Write BW', '', '', '', '', '', total_write])
    for cell in ws[ws.max_row]:
        cell.fill = total_fill
        cell.font = bold_font
    for idx, width in enumerate([10,18,14,18,18,14,18], start=1):
        ws.column_dimensions[get_column_letter(idx)].width = width


def add_rnf_sheet():
    ws = wb.create_sheet('RNF')
    headers = ['CMN','NodeID'] + [f'ReadCount_{wp}' for wp in RNF_READ_WP] + ['ReadTotalCount','ReadTime_s','ReadBW_GBps'] + [f'WriteCount_{wp}' for wp in RNF_WRITE_WP] + ['WriteTotalCount','WriteTime_s','WriteBW_GBps']
    ws.append(headers)
    style_header(ws)
    for cmn in CMNS:
        ws.append([f'RNF - {cmn}'])
        for cell in ws[ws.max_row]:
            cell.fill = section_fill
            cell.font = bold_font
        for nodeid in RNF_NODEIDS:
            read_entry = agg.get(('RNF', cmn, nodeid, 'read'), {'counts':{}, 'times':{}})
            write_entry = agg.get(('RNF', cmn, nodeid, 'write'), {'counts':{}, 'times':{}})
            read_total = total_count(read_entry, RNF_READ_WP)
            read_time = avg_time_for(read_entry, RNF_READ_WP)
            read_bw = (read_total * 64 / read_time / 1_000_000_000) if read_time else 0.0
            write_total = total_count(write_entry, RNF_WRITE_WP)
            write_time = avg_time_for(write_entry, RNF_WRITE_WP)
            write_bw = (write_total * 64 / write_time / 1_000_000_000) if write_time else 0.0
            summary['RNF'][cmn]['read'] += read_bw
            summary['RNF'][cmn]['write'] += write_bw
            row_data = [cmn, nodeid]
            row_data.extend(read_entry['counts'].get(wp, 0) for wp in RNF_READ_WP)
            row_data.extend([read_total, read_time, read_bw])
            row_data.extend(write_entry['counts'].get(wp, 0) for wp in RNF_WRITE_WP)
            row_data.extend([write_total, write_time, write_bw])
            ws.append(row_data)
        ws.append([f'Total RNF Read BW ({cmn})'] + [''] * (len(headers)-2) + [summary['RNF'][cmn]['read']])
        for cell in ws[ws.max_row]:
            cell.fill = total_fill
            cell.font = bold_font
        row = [''] * len(headers)
        row[0] = f'Total RNF Write BW ({cmn})'
        row[-1] = summary['RNF'][cmn]['write']
        ws.append(row)
        for cell in ws[ws.max_row]:
            cell.fill = total_fill
            cell.font = bold_font
        ws.append([])
    for idx, width in enumerate([14,12] + [16]*(len(headers)-2), start=1):
        ws.column_dimensions[get_column_letter(idx)].width = width


def add_snf_sheet():
    ws = wb.create_sheet('SNF')
    headers = [
        'CMN',
        'ReqsLocalSN_Count',
        'RetriesLocal_Count',
        'TimeElapsed_s',
        'TotalBW_InclRetries_GBps',
        'RetryBW_GBps',
        'SNF_EffectiveBW_GBps',
        'RetryRatio_pct',
    ]
    ws.append(headers)
    style_header(ws)
    for cmn in CMNS:
        entry = agg.get(('SNF_MC', cmn, '', 'local_sn'), {'counts':{}, 'times':{}})
        reqs = entry['counts'].get('hns_mc_reqs_local_sn', 0)
        retries = entry['counts'].get('hns_mc_retries_local_sn', 0)
        # Both events are issued in one perf command, so use the shared elapsed time.
        time_s = avg_time_for(entry, ['hns_mc_reqs_local_sn']) or avg_time_for(entry, ['hns_mc_retries_local_sn'])
        total_bw = (reqs * 64 / time_s / 1_000_000_000) if time_s else 0.0
        retry_bw = (retries * 64 / time_s / 1_000_000_000) if time_s else 0.0
        effective_count = max(reqs - retries, 0)
        effective_bw = (effective_count * 64 / time_s / 1_000_000_000) if time_s else 0.0
        retry_ratio = ((retries / reqs) * 100.0) if reqs else 0.0
        summary['SNF'][cmn]['reqs'] = reqs
        summary['SNF'][cmn]['retries'] = retries
        summary['SNF'][cmn]['time_s'] = time_s
        summary['SNF'][cmn]['total'] = total_bw
        summary['SNF'][cmn]['retry'] = retry_bw
        summary['SNF'][cmn]['net'] = effective_bw
        summary['SNF'][cmn]['retry_ratio'] = retry_ratio
        ws.append([cmn, reqs, retries, time_s, total_bw, retry_bw, effective_bw, retry_ratio])
    for idx, width in enumerate([14,20,20,16,24,18,24,14], start=1):
        ws.column_dimensions[get_column_letter(idx)].width = width



def add_ccg_sheet():
    ws = wb.create_sheet('CCG')
    headers = ['CMN','NodeID','UpCount','UpTime_s','UpBW_GBps','DownCount','DownTime_s','DownBW_GBps']
    ws.append(headers)
    style_header(ws)
    for cmn in CMNS:
        ws.append([f'CCG - {cmn}'])
        for cell in ws[ws.max_row]:
            cell.fill = section_fill
            cell.font = bold_font
        for nodeid in CCG_NODEIDS:
            up_entry = agg.get(('CCG', cmn, nodeid, 'up'), {'counts':{}, 'times':{}})
            down_entry = agg.get(('CCG', cmn, nodeid, 'down'), {'counts':{}, 'times':{}})
            up_total = total_count(up_entry, CCG_WP)
            up_time = avg_time_for(up_entry, CCG_WP)
            up_bw = (up_total * 64 / up_time / 1_000_000_000) if up_time else 0.0
            down_total = total_count(down_entry, CCG_WP)
            down_time = avg_time_for(down_entry, CCG_WP)
            down_bw = (down_total * 64 / down_time / 1_000_000_000) if down_time else 0.0
            summary['CCG'][cmn]['up'] += up_bw
            summary['CCG'][cmn]['down'] += down_bw
            ws.append([cmn, nodeid, up_total, up_time, up_bw, down_total, down_time, down_bw])
        ws.append([f'Total CCG Up BW ({cmn})', '', '', '', summary['CCG'][cmn]['up'], '', '', ''])
        for cell in ws[ws.max_row]:
            cell.fill = total_fill
            cell.font = bold_font
        ws.append([f'Total CCG Down BW ({cmn})', '', '', '', '', '', '', summary['CCG'][cmn]['down']])
        for cell in ws[ws.max_row]:
            cell.fill = total_fill
            cell.font = bold_font
        ws.append([])
    for idx, width in enumerate([14,12,14,14,14,14,14,14], start=1):
        ws.column_dimensions[get_column_letter(idx)].width = width

add_cpu_sheet()
add_rnf_sheet()
add_snf_sheet()
add_ccg_sheet()

ws_summary = wb.create_sheet('Summary')
ws_summary.append(['Metric', 'Value', 'Unit'])
style_header(ws_summary)
for cmn in CMNS:
    cpu_read = summary['CPU']['cpu']['read']
    cpu_write = summary['CPU']['cpu']['write']
    rnf_read_retry = summary['RNF'][cmn]['read'] - cpu_read
    rnf_write_retry = summary['RNF'][cmn]['write'] - cpu_write
    rnf_read_retry_ratio = (rnf_read_retry / summary['RNF'][cmn]['read'] * 100.0) if summary['RNF'][cmn]['read'] else 0.0
    rnf_write_retry_ratio = (rnf_write_retry / summary['RNF'][cmn]['write'] * 100.0) if summary['RNF'][cmn]['write'] else 0.0
    ws_summary.append([f'RNF Watchpoint Total Read BW ({cmn})', summary['RNF'][cmn]['read'], 'GBps'])
    ws_summary.append([f'RNF Watchpoint Total Write BW ({cmn})', summary['RNF'][cmn]['write'], 'GBps'])
    ws_summary.append([f'CPU PMU Total Read BW 0x60', cpu_read, 'GBps'])
    ws_summary.append([f'CPU PMU Total Write BW 0x61', cpu_write, 'GBps'])
    ws_summary.append([f'RNF Read Retry BW ({cmn})', rnf_read_retry, 'GBps'])
    ws_summary.append([f'RNF Write Retry BW ({cmn})', rnf_write_retry, 'GBps'])
    ws_summary.append([f'RNF Read Retry Ratio ({cmn})', rnf_read_retry_ratio, '%'])
    ws_summary.append([f'RNF Write Retry Ratio ({cmn})', rnf_write_retry_ratio, '%'])
    ws_summary.append([f'SNF Total BW incl retries ({cmn})', summary['SNF'][cmn]['total'], 'GBps'])
    ws_summary.append([f'HNS MC Retry BW local ({cmn})', summary['SNF'][cmn]['retry'], 'GBps'])
    ws_summary.append([f'SNF Effective BW excl retries ({cmn})', summary['SNF'][cmn]['net'], 'GBps'])
    ws_summary.append([f'SNF Retry Ratio ({cmn})', summary['SNF'][cmn]['retry_ratio'], '%'])
    ws_summary.append([f'CCG Total Up BW ({cmn})', summary['CCG'][cmn]['up'], 'GBps'])
    ws_summary.append([f'CCG Total Down BW ({cmn})', summary['CCG'][cmn]['down'], 'GBps'])
ws_summary.column_dimensions['A'].width = 42
ws_summary.column_dimensions['B'].width = 16
ws_summary.column_dimensions['C'].width = 10

for ws in wb.worksheets:
    for row in ws.iter_rows(min_row=2):
        for cell in row:
            if isinstance(cell.value, float):
                cell.number_format = '0.000000'

wb.save(out_path)
print('===== TOTALS =====')
for cmn in CMNS:
    cpu_read = summary['CPU']['cpu']['read']
    cpu_write = summary['CPU']['cpu']['write']
    rnf_read_retry = summary['RNF'][cmn]['read'] - cpu_read
    rnf_write_retry = summary['RNF'][cmn]['write'] - cpu_write
    rnf_read_retry_ratio = (rnf_read_retry / summary['RNF'][cmn]['read'] * 100.0) if summary['RNF'][cmn]['read'] else 0.0
    rnf_write_retry_ratio = (rnf_write_retry / summary['RNF'][cmn]['write'] * 100.0) if summary['RNF'][cmn]['write'] else 0.0
    print(f'RNF Watchpoint Total Read BW ({cmn}):  {summary["RNF"][cmn]["read"]:.6f} GBps')
    print(f'RNF Watchpoint Total Write BW ({cmn}): {summary["RNF"][cmn]["write"]:.6f} GBps')
    print(f'CPU PMU Total Read BW 0x60:       {cpu_read:.6f} GBps')
    print(f'CPU PMU Total Write BW 0x61:      {cpu_write:.6f} GBps')
    print(f'RNF Read Retry BW:                {rnf_read_retry:.6f} GBps')
    print(f'RNF Write Retry BW:               {rnf_write_retry:.6f} GBps')
    print(f'RNF Read Retry Ratio:             {rnf_read_retry_ratio:.2f}%')
    print(f'RNF Write Retry Ratio:            {rnf_write_retry_ratio:.2f}%')
    print(f'SNF Total BW incl retries ({cmn}): {summary["SNF"][cmn]["total"]:.6f} GBps')
    print(f'HNS MC Retry BW local ({cmn}):   {summary["SNF"][cmn]["retry"]:.6f} GBps')
    print(f'SNF Effective BW excl retries ({cmn}): {summary["SNF"][cmn]["net"]:.6f} GBps')
    print(f'SNF Retry Ratio ({cmn}):         {summary["SNF"][cmn]["retry_ratio"]:.2f}%')
    print(f'CCG Total Up BW ({cmn}):         {summary["CCG"][cmn]["up"]:.6f} GBps')
    print(f'CCG Total Down BW ({cmn}):       {summary["CCG"][cmn]["down"]:.6f} GBps')
print(f'Excel written to: {out_path}')
PY
}
main() {
  if [[ $PARSE_ONLY -eq 1 ]]; then
    [[ -f "$INPUT_RAW" ]] || { echo "Missing raw file: $INPUT_RAW" >&2; exit 1; }
    parse_raw_to_excel "$INPUT_RAW"
    return
  fi

  write_combined_commands
  run_perf_commands

  if [[ $RUN_ONLY -eq 0 ]]; then
    parse_raw_to_excel "$RAW_FILE"
  fi

  echo "Raw output   : $RAW_FILE"
  echo "Combined cmds: $COMBINED_FILE"
  [[ $RUN_ONLY -eq 0 ]] && echo "Excel output : $XLSX_FILE"
}

main "$@"
