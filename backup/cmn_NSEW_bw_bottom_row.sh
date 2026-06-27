#!/bin/bash
set -euo pipefail

OUTDIR="${OUTDIR:-cmn_bw}"
SAMPLE_TIME="${SAMPLE_TIME:-0.1}"
SAMPLES="${SAMPLES:-10}"
FLIT_BYTES="${FLIT_BYTES:-32}"

NODES=(0x00 0x80 0x100 0x180 0x200 0x280 0x300 0x380 0x400)
CMNS=(arm_cmn_0 arm_cmn_1)

mkdir -p "$OUTDIR"

for cmn in "${CMNS[@]}"; do
    for node in "${NODES[@]}"; do
        csv="${OUTDIR}/${cmn}_node_${node#0x}.csv"
        echo "timestamp,sample,node,n_flits,s_flits,e_flits,w_flits,total_flits,n_Bps,s_Bps,e_Bps,w_Bps,total_Bps" > "$csv"
    done
done

for ((sample=1; sample<=SAMPLES; sample++)); do
    ts=$(date +%s.%N)

    for cmn in "${CMNS[@]}"; do
        for node in "${NODES[@]}"; do
            tmp=$(mktemp)

            perf stat -x , \
                -e "${cmn}/mxp_n_dat_txflit_valid,nodeid=${node},bynodeid=1/" \
                -e "${cmn}/mxp_s_dat_txflit_valid,nodeid=${node},bynodeid=1/" \
                -e "${cmn}/mxp_e_dat_txflit_valid,nodeid=${node},bynodeid=1/" \
                -e "${cmn}/mxp_w_dat_txflit_valid,nodeid=${node},bynodeid=1/" \
                -a -- sleep "$SAMPLE_TIME" \
                2> "$tmp"

            n=$(grep mxp_n_dat_txflit_valid "$tmp" | head -1 | cut -d, -f1 | tr -d ' ')
            s=$(grep mxp_s_dat_txflit_valid "$tmp" | head -1 | cut -d, -f1 | tr -d ' ')
            e=$(grep mxp_e_dat_txflit_valid "$tmp" | head -1 | cut -d, -f1 | tr -d ' ')
            w=$(grep mxp_w_dat_txflit_valid "$tmp" | head -1 | cut -d, -f1 | tr -d ' ')

            rm -f "$tmp"

            n=${n:-0}
            s=${s:-0}
            e=${e:-0}
            w=${w:-0}

            total_flits=$((n + s + e + w))

            n_bw=$(awk "BEGIN {print (${n}*${FLIT_BYTES})/${SAMPLE_TIME}}")
            s_bw=$(awk "BEGIN {print (${s}*${FLIT_BYTES})/${SAMPLE_TIME}}")
            e_bw=$(awk "BEGIN {print (${e}*${FLIT_BYTES})/${SAMPLE_TIME}}")
            w_bw=$(awk "BEGIN {print (${w}*${FLIT_BYTES})/${SAMPLE_TIME}}")
            total_bw=$(awk "BEGIN {print (${total_flits}*${FLIT_BYTES})/${SAMPLE_TIME}}")

            csv="${OUTDIR}/${cmn}_node_${node#0x}.csv"
            echo "${ts},${sample},${node},${n},${s},${e},${w},${total_flits},${n_bw},${s_bw},${e_bw},${w_bw},${total_bw}" >> "$csv"
        done
    done
done
