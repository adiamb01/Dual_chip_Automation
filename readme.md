# Phoenix Performance Automation

This repository contains automation scripts for collecting CPU PMU and CMN performance statistics on Phoenix platforms.

## Repository Contents

| Script                                              | Purpose                                                                |
| --------------------------------------------------- | ---------------------------------------------------------------------- |
| `SE_Perf_CPU_SNF_CCG_NoRetry_BW_HNSMC_retry_pct.sh` | CPU PMU, SN-F, HNS MC and CCG bandwidth collection                     |
| `cbusy_throttle_automation.sh`                      | CPU CBusy, HN-S CBusy, PoCQ, L2 TQ, cache and memory-throttle analysis |
| `backup/`                                           | Legacy scripts retained for reference                                  |

---

# Prerequisites

## PMU Driver

Install the latest CESW CPU + CMN PMU driver.

Verify the required events are available:

```bash
perf list
```

If necessary, use the latest perf binary released together with the PMU driver.

---

## Python

```bash
sudo apt-get update
sudo apt-get install -y python3-pip

python3 -m pip install openpyxl --break-system-packages
```

---

# 1. Bandwidth Collection

Script:

```text
SE_Perf_CPU_SNF_CCG_NoRetry_BW_HNSMC_retry_pct.sh
```

## Metrics

* Per-CPU PMU read bandwidth
* Per-CPU PMU write bandwidth
* SN-F read bandwidth
* SN-F write bandwidth (retry excluded)
* HNS MC request bandwidth
* HNS MC retry bandwidth
* HNS MC retry percentage
* CCG C2C read/write bandwidth

## Example

```bash
./SE_Perf_CPU_SNF_CCG_NoRetry_BW_HNSMC_retry_pct.sh \
    --out-dir results \
    --sleep 1 \
    --cmn 0,1
```

### Output

* `raw_perf_stats.txt`
* `combined_perf_commands.txt`
* `parsed_perf_stats.xlsx`

Workbook contains:

* RawData
* CPU_PMU
* SNF_NoRetry
* SNF_MC
* CCG_C2C
* Summary

---

# 2. CBusy / Throttle Analysis

Script:

```text
cbusy_throttle_automation.sh
```

## Metrics

### CPU

* Cycles
* Instructions
* IPC
* Backend stalls
* L2 TQ FULL
* CBusy0
* CBusy1
* CBusy2
* CBusy3
* MT CBusy

### CMN

* HN-S CBusy0
* HN-S CBusy1
* HN-S CBusy2
* HN-S CBusy3
* PoCQ Occupancy
* PoCQ Retry
* Cache Accesses
* Cache Misses
* Cache Fills
* Cache Evictions

### Memory-side

* HNS throttling
* HNI stalls
* HNP stalls
* SBSX stalls
* Memory backpressure events (when available)

---

## Example

CMN0 only:

```bash
./cbusy_throttle_automation.sh \
    60 \
    500 \
    0 \
    0 \
    2.8GHz \
    2.0GHz
```

Both CMNs:

```bash
./cbusy_throttle_automation.sh \
    60 \
    500 \
    0 \
    both \
    2.8GHz \
    2.0GHz
```

Arguments:

| Argument  | Description                                |
| --------- | ------------------------------------------ |
| Duration  | Collection duration (seconds)              |
| Interval  | Sampling interval (ms)                     |
| CPU       | CPU list                                   |
| CMN       | `0`, `1` or `both`                         |
| CPU Clock | Used for L2 TQ normalization               |
| CMN Clock | Used for HN-S CBusy and PoCQ normalization |

---

## Output

The script generates:

```text
raw/
summary/
meta/
```

under:

```text
/root/cmn_results/cbusy_snapshot_nomux_<timestamp>/
```

### Key output files

| File                                      | Description             |
| ----------------------------------------- | ----------------------- |
| `summary.txt`                             | Human-readable report   |
| `combined_summary.csv`                    | High-level KPIs (%)     |
| `cpu_cbusy_per_node_percent.csv`          | Per-CPU CBusy           |
| `cmn_hns_cbusy_per_hns_percent.csv`       | Per-HN-S CBusy          |
| `cmn_pocq_occupancy_per_hns_with_pct.csv` | Per-HN-S PoCQ occupancy |

---

## Normalization

The script reports normalized percentages.

### CPU L2 TQ

```
L2_TQ % =
Count /
(CPU Clock × Sample Time)
```

### HN-S CBusy

Each CBusy level is normalized independently.

```
CBusy % =
Count /
(CMN Clock × Sample Time × Number of HN-S monitored)
```

CBusy levels are **not** summed before normalization.

### PoCQ Occupancy

```
PoCQ % =
Count /
(CMN Clock × Sample Time × Number of HN-S monitored)
```

If only CMN0 or CMN1 is selected, the HN-S divisor is automatically adjusted.

---

# Parsing Existing Results

Bandwidth:

```bash
./SE_Perf_CPU_SNF_CCG_NoRetry_BW_HNSMC_retry_pct.sh \
    --parse-only raw_perf_stats.txt
```

CBusy:

```bash
./cbusy_throttle_automation.sh \
    --parse-only \
    <capture_directory> \
    2.8GHz \
    2.0GHz
```

