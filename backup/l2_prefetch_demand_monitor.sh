#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  sudo ./l2_prefetch_demand_monitor.sh monitor -c <cores> -i <ms> -d <sec> -o <outfile>
  ./l2_prefetch_demand_monitor.sh parse -o <outfile>

Examples:
  sudo ./l2_prefetch_demand_monitor.sh monitor -c 0 -i 1000 -d 30 -o l2_run.log
  ./l2_prefetch_demand_monitor.sh parse -o l2_run.log

Outputs:
  <outfile>
  <outfile>.summary.csv
  <outfile>.metrics.csv
EOF
}

mode="${1:-}"
shift || true

CORES="0"
INTERVAL_MS="1000"
DURATION_SEC="30"
OUTFILE="l2_run.log"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--cores) CORES="$2"; shift 2 ;;
    -i|--interval-ms) INTERVAL_MS="$2"; shift 2 ;;
    -d|--duration) DURATION_SEC="$2"; shift 2 ;;
    -o|--output) OUTFILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

SUMMARY="${OUTFILE}.summary.csv"
METRICS="${OUTFILE}.metrics.csv"
TMPERR="${OUTFILE}.perf.stderr"

EVENTS=(
  r223
  l2d_cache
  l2d_cache_refill
  l2d_cache_refill_rd
  l2d_cache_refill_wr
  l1d_cache
  l1d_cache_refill
  l1d_cache_refill_rd
  l1d_cache_refill_wr
  mem_access
  bus_access
  bus_cycles
  cpu_cycles
  instructions
)

event_csv() {
  local IFS=,
  echo "${EVENTS[*]}"
}

parse_summary() {
  awk -F, '
    BEGIN {
      print "event,total_count"
    }

    function trim(x) {
      gsub(/^[ \t\r\n]+/, "", x)
      gsub(/[ \t\r\n]+$/, "", x)
      return x
    }

    /^[ \t]*#/ { next }
    NF < 4 { next }

    {
      count = trim($2)
      event = trim($4)

      gsub(/,/, "", count)

      if (event == "") next
      if (count == "") next
      if (count !~ /^[0-9]+$/) next

      total[event] += count
    }

    END {
      for (e in total) {
        print e "," total[e]
      }
    }
  ' "$OUTFILE" | sort -t, -k1,1 > "$SUMMARY"
}

parse_metrics() {
  awk -F, '
    NR == 1 && $1 == "event" { next }

    {
      v[$1] = $2 + 0
    }

    function pct(a,b) {
      return b ? (100.0 * a / b) : 0
    }

    function ratio(a,b) {
      return b ? (1.0 * a / b) : 0
    }

    function mpki(a,inst) {
      return inst ? (1000.0 * a / inst) : 0
    }

    END {
      inst = v["instructions"]
      cyc  = v["cpu_cycles"]

      print "metric,value"

      printf "instructions,%d\n", inst
      printf "cpu_cycles,%d\n", cyc
      printf "IPC,%.9f\n", ratio(inst, cyc)
      printf "CPI,%.9f\n", ratio(cyc, inst)

      printf "l1d_cache,%d\n", v["l1d_cache"]
      printf "l1d_cache_refill,%d\n", v["l1d_cache_refill"]
      printf "L1_MISS_RATE_PCT,%.9f\n", pct(v["l1d_cache_refill"], v["l1d_cache"])
      printf "L1_MPKI,%.9f\n", mpki(v["l1d_cache_refill"], inst)
      printf "L1_RD_REFILL_PCT,%.9f\n", pct(v["l1d_cache_refill_rd"], v["l1d_cache_refill"])
      printf "L1_WR_REFILL_PCT,%.9f\n", pct(v["l1d_cache_refill_wr"], v["l1d_cache_refill"])

      printf "l2d_cache,%d\n", v["l2d_cache"]
      printf "l2d_cache_refill,%d\n", v["l2d_cache_refill"]
      printf "L2_MISS_RATE_PCT,%.9f\n", pct(v["l2d_cache_refill"], v["l2d_cache"])
      printf "L2_MPKI,%.9f\n", mpki(v["l2d_cache_refill"], inst)
      printf "L2_RD_REFILL_PCT,%.9f\n", pct(v["l2d_cache_refill_rd"], v["l2d_cache_refill"])
      printf "L2_WR_REFILL_PCT,%.9f\n", pct(v["l2d_cache_refill_wr"], v["l2d_cache_refill"])

      printf "DEMAND_MISS_R223,%d\n", v["r223"]
      printf "DEMAND_MPKI,%.9f\n", mpki(v["r223"], inst)
      printf "DEMAND_AS_PCT_OF_L2_REFILLS,%.9f\n", pct(v["r223"], v["l2d_cache_refill"])
      printf "DEMAND_AS_PCT_OF_L2_ACCESSES,%.9f\n", pct(v["r223"], v["l2d_cache"])

      printf "mem_access,%d\n", v["mem_access"]
      printf "MEM_ACCESS_PER_INST,%.9f\n", ratio(v["mem_access"], inst)

      printf "bus_access,%d\n", v["bus_access"]
      printf "BUS_ACCESS_PER_INST,%.9f\n", ratio(v["bus_access"], inst)

      printf "bus_cycles,%d\n", v["bus_cycles"]
      printf "BUS_CYCLES_PER_CPU_CYCLE,%.9f\n", ratio(v["bus_cycles"], cyc)
    }
  ' "$SUMMARY" > "$METRICS"
}

run_monitor() {
  rm -f "$OUTFILE" "$SUMMARY" "$METRICS" "$TMPERR"

  perf stat \
    -x, \
    -I "$INTERVAL_MS" \
    -C "$CORES" \
    -e "$(event_csv)" \
    sleep "$DURATION_SEC" \
    > "$OUTFILE" \
    2> "$TMPERR" || {
      echo "perf failed. See: $TMPERR" >&2
      exit 1
    }

  parse_summary
  parse_metrics

  rm -f "$TMPERR"

  echo "Files written:"
  echo "  $OUTFILE"
  echo "  $SUMMARY"
  echo "  $METRICS"
}

case "$mode" in
  monitor)
    run_monitor
    ;;
  parse)
    parse_summary
    parse_metrics
    echo "Files written:"
    echo "  $SUMMARY"
    echo "  $METRICS"
    ;;
  *)
    usage
    exit 1
    ;;
esac
