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
  ./dual_chip_automation_single.sh [options]

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
  for cmn in 0 1; do
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

  # SNF: watchpoint_down, wp_dev_sel=0
  for cmn in 0 1; do
    for wp in "${SNF_READ_WP[@]}"; do
      for nodeid in "${SNF_NODEIDS[@]}"; do
        printf 'perf stat -e arm_cmn_%s/watchpoint_down,wp_chn_sel=0,nodeid=%s,bynodeid=1,wp_dev_sel=0,wp_grp=0,wp_val=%s,wp_mask=0xfffffff01fffffff/ -a -- sleep %s\n' \
          "$cmn" "$nodeid" "$wp" "$SLEEP_SECS" >> "$COMBINED_FILE"
      done
    done
    for wp in "${SNF_WRITE_WP[@]}"; do
      for nodeid in "${SNF_NODEIDS[@]}"; do
        printf 'perf stat -e arm_cmn_%s/watchpoint_down,wp_chn_sel=0,nodeid=%s,bynodeid=1,wp_dev_sel=0,wp_grp=0,wp_val=%s,wp_mask=0xfffffff01fffffff/ -a -- sleep %s\n' \
          "$cmn" "$nodeid" "$wp" "$SLEEP_SECS" >> "$COMBINED_FILE"
      done
    done
  done

  # CCG: watchpoint_up and watchpoint_down, wp_dev_sel=1, exclusive
  for cmn in 0 1; do
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
CCG_WP = ['0x740000000']
RNF_NODESET = set(RNF_NODEIDS)
SNF_NODESET = set(SNF_NODEIDS)
CCG_NODESET = set(CCG_NODEIDS)
cmd_re = re.compile(r'COMMAND:\s*perf\s+stat\s+-e\s+(arm_cmn_[01])/(watchpoint_up|watchpoint_down),.*?nodeid=(0x[0-9a-fA-F]+).*?wp_val=(0x[0-9a-fA-F]+)', re.IGNORECASE)
time_re = re.compile(r'^\s*([0-9]*\.?[0-9]+)\s+seconds\s+time\s+elapsed', re.IGNORECASE)
perf_re = re.compile(r'arm_cmn_[01]/watchpoint_(?:up|down)', re.IGNORECASE)


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
    if nodeid in SNF_NODESET:
        if wp_val in SNF_READ_WP:
            return 'SNF', 'read'
        if wp_val in SNF_WRITE_WP:
            return 'SNF', 'write'
    if nodeid in CCG_NODESET and wp_val in CCG_WP:
        return 'CCG', 'up' if watch_dir == 'watchpoint_up' else 'down'
    return None, None

records = []
current = None
with raw_path.open('r', encoding='utf-8', errors='replace') as f:
    for raw_line in f:
        line = raw_line.rstrip('\n')
        m = cmd_re.search(line)
        if m:
            cmn, watch_dir, nodeid, wp_val = m.groups()
            category, direction = classify(nodeid, wp_val, watch_dir)
            current = {
                'cmn': cmn,
                'watch_dir': watch_dir.lower(),
                'nodeid': nodeid.lower(),
                'wp_val': wp_val.lower(),
                'category': category,
                'direction': direction,
                'count': None,
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
                current['count'] = count
            continue
        tm = time_re.search(line)
        if tm:
            current['time_s'] = float(tm.group(1))
            records.append(current)
            current = None
if current is not None:
    records.append(current)

records = [r for r in records if r['category'] is not None]
for r in records:
    r['bytes'] = (r['count'] or 0) * 64
    r['bw_gbps'] = (r['bytes'] / r['time_s'] / 1_000_000_000) if r['count'] is not None and r['time_s'] else None

node_order = {'RNF': RNF_NODEIDS, 'SNF': SNF_NODEIDS, 'CCG': CCG_NODEIDS}
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
    'SNF': defaultdict(lambda: {'read': 0.0, 'write': 0.0}),
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
for width_idx, width in enumerate([12,12,12,12,16,14,16,14,14,12,90], start=1):
    ws_raw.column_dimensions[get_column_letter(width_idx)].width = width


def add_sheet_for_rnf_snf(sheet_name, category, read_wp, write_wp):
    ws = wb.create_sheet(sheet_name)
    headers = ['CMN','NodeID'] + [f'ReadCount_{wp}' for wp in read_wp] + ['ReadTotalCount','ReadTime_s','ReadBW_GBps'] + [f'WriteCount_{wp}' for wp in write_wp] + ['WriteTotalCount','WriteTime_s','WriteBW_GBps']
    ws.append(headers)
    for c in ws[1]:
        c.fill = header_fill
        c.font = header_font
    for cmn in ['arm_cmn_0', 'arm_cmn_1']:
        ws.append([f'{category} - {cmn}'])
        for cell in ws[ws.max_row]:
            cell.fill = section_fill
            cell.font = bold_font
        for nodeid in node_order[category]:
            read_entry = agg.get((category, cmn, nodeid, 'read'), {'counts':{}, 'times':{}})
            write_entry = agg.get((category, cmn, nodeid, 'write'), {'counts':{}, 'times':{}})
            read_total = total_count(read_entry, read_wp)
            read_time = avg_time_for(read_entry, read_wp)
            read_bw = (read_total * 64 / read_time / 1_000_000_000) if read_time else 0.0
            write_total = total_count(write_entry, write_wp)
            write_time = avg_time_for(write_entry, write_wp)
            write_bw = (write_total * 64 / write_time / 1_000_000_000) if write_time else 0.0
            summary[category][cmn]['read'] += read_bw
            summary[category][cmn]['write'] += write_bw
            row_data = [cmn, nodeid]
            row_data.extend(read_entry['counts'].get(wp, 0) for wp in read_wp)
            row_data.extend([read_total, read_time, read_bw])
            row_data.extend(write_entry['counts'].get(wp, 0) for wp in write_wp)
            row_data.extend([write_total, write_time, write_bw])
            ws.append(row_data)
        read_total_row = [f'Total {category} Read BW ({cmn})'] + [''] * (len(headers)-2) + [summary[category][cmn]['read']]
        ws.append(read_total_row)
        for cell in ws[ws.max_row]:
            cell.fill = total_fill
            cell.font = bold_font
        write_total_row = [''] * len(headers)
        write_total_row[0] = f'Total {category} Write BW ({cmn})'
        write_total_row[-1] = summary[category][cmn]['write']
        ws.append(write_total_row)
        for cell in ws[ws.max_row]:
            cell.fill = total_fill
            cell.font = bold_font
        ws.append([])
    for idx, width in enumerate([14,12] + [16]*(len(headers)-2), start=1):
        ws.column_dimensions[get_column_letter(idx)].width = width


def add_ccg_sheet():
    ws = wb.create_sheet('CCG')
    headers = ['CMN','NodeID','UpCount','UpTime_s','UpBW_GBps','DownCount','DownTime_s','DownBW_GBps']
    ws.append(headers)
    for c in ws[1]:
        c.fill = header_fill
        c.font = header_font
    for cmn in ['arm_cmn_0', 'arm_cmn_1']:
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

add_sheet_for_rnf_snf('RNF', 'RNF', RNF_READ_WP, RNF_WRITE_WP)
add_sheet_for_rnf_snf('SNF', 'SNF', SNF_READ_WP, SNF_WRITE_WP)
add_ccg_sheet()

ws_summary = wb.create_sheet('Summary')
ws_summary.append(['Metric', 'Value_GBps'])
for c in ws_summary[1]:
    c.fill = header_fill
    c.font = header_font
for cmn in ['arm_cmn_0', 'arm_cmn_1']:
    ws_summary.append([f'RNF Total Read BW ({cmn})', summary['RNF'][cmn]['read']])
    ws_summary.append([f'RNF Total Write BW ({cmn})', summary['RNF'][cmn]['write']])
for cmn in ['arm_cmn_0', 'arm_cmn_1']:
    ws_summary.append([f'SNF Total Read BW ({cmn})', summary['SNF'][cmn]['read']])
    ws_summary.append([f'SNF Total Write BW ({cmn})', summary['SNF'][cmn]['write']])
for cmn in ['arm_cmn_0', 'arm_cmn_1']:
    ws_summary.append([f'CCG Total Up BW ({cmn})', summary['CCG'][cmn]['up']])
    ws_summary.append([f'CCG Total Down BW ({cmn})', summary['CCG'][cmn]['down']])
ws_summary.column_dimensions['A'].width = 32
ws_summary.column_dimensions['B'].width = 14

for ws in wb.worksheets:
    for row in ws.iter_rows(min_row=2):
        for cell in row:
            if isinstance(cell.value, float):
                cell.number_format = '0.000000'

wb.save(out_path)
print('===== TOTALS =====')
for cmn in ['arm_cmn_0', 'arm_cmn_1']:
    print(f'RNF Total Read BW ({cmn}):  {summary["RNF"][cmn]["read"]:.6f} GBps')
    print(f'RNF Total Write BW ({cmn}): {summary["RNF"][cmn]["write"]:.6f} GBps')
for cmn in ['arm_cmn_0', 'arm_cmn_1']:
    print(f'SNF Total Read BW ({cmn}):  {summary["SNF"][cmn]["read"]:.6f} GBps')
    print(f'SNF Total Write BW ({cmn}): {summary["SNF"][cmn]["write"]:.6f} GBps')
for cmn in ['arm_cmn_0', 'arm_cmn_1']:
    print(f'CCG Total Up BW ({cmn}):    {summary["CCG"][cmn]["up"]:.6f} GBps')
    print(f'CCG Total Down BW ({cmn}):  {summary["CCG"][cmn]["down"]:.6f} GBps')
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
