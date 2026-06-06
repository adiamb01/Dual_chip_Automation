#!/bin/bash
set -euo pipefail

DIR="${1:-cmn_bw}"
OUT="${2:-cmn_dat_summary.csv}"

echo "cmn,node,n_flits,s_flits,e_flits,w_flits,total_flits,n_pct,s_pct,e_pct,w_pct" > "$OUT"

for f in "$DIR"/arm_cmn_*_node_*.csv; do
    [ -f "$f" ] || continue

    base=$(basename "$f")
    cmn=$(echo "$base" | sed -E 's/^(arm_cmn_[0-9]+)_node_.*/\1/')
    node=$(echo "$base" | sed -E 's/^arm_cmn_[0-9]+_node_([^.]*)\.csv/\1/')

    last=$(tail -n 1 "$f")

    n=$(echo "$last" | awk -F, '{print $4}')
    s=$(echo "$last" | awk -F, '{print $5}')
    e=$(echo "$last" | awk -F, '{print $6}')
    w=$(echo "$last" | awk -F, '{print $7}')
    total=$(echo "$last" | awk -F, '{print $8}')

    [ -z "$total" ] && total=0

    if [ "$total" -gt 0 ]; then
        n_pct=$(awk "BEGIN {printf \"%.2f\", 100*$n/$total}")
        s_pct=$(awk "BEGIN {printf \"%.2f\", 100*$s/$total}")
        e_pct=$(awk "BEGIN {printf \"%.2f\", 100*$e/$total}")
        w_pct=$(awk "BEGIN {printf \"%.2f\", 100*$w/$total}")
    else
        n_pct=0
        s_pct=0
        e_pct=0
        w_pct=0
    fi

    echo "$cmn,0x$node,$n,$s,$e,$w,$total,$n_pct,$s_pct,$e_pct,$w_pct" >> "$OUT"
done

echo
echo "Summary written to: $OUT"
column -s, -t "$OUT"
