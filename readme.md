# Dual Chip Performance Automation

## Overview

This repository contains automation scripts for collecting and parsing CPU PMU, CMN, SN-F, HNS Memory Controller (HNS MC), and CCG bandwidth statistics on Phoenix platforms.

The primary supported tool is:

```bash
SE_Perf_CPU_SNF_CCG_NoRetry_BW_HNSMC_retry_pct.sh
```

The script collects:

* Per-CPU PMU read/write bandwidth
* SN-F read/write bandwidth (write bandwidth excludes retries)
* HNS Memory Controller request and retry statistics
* Retry bandwidth and retry percentage
* CCG C2C read/write bandwidth
* Per-node and chip-level bandwidth summaries

---

# Prerequisites

## 1. PMU Driver

Install the latest CESW CPU + CMN PMU driver.

Verify that all required events are available:

```bash
perf list
```

If the required events are missing, ensure the correct `perf` binary is installed.

If necessary:

```bash
ln -sf <compiled_perf_binary> /usr/bin/perf
```

The compiled perf binary is released together with the CESW PMU driver.

---

## 2. Python Dependencies

Install Python and OpenPyXL:

```bash
sudo apt-get update
sudo apt-get install -y python3-pip

python3 -m pip install openpyxl --break-system-packages
```

---

# Running the Tool

1. Launch the workload.
2. Ensure all workload threads have started.
3. Execute the script.

Example:

```bash
./SE_Perf_CPU_SNF_CCG_NoRetry_BW_HNSMC_retry_pct.sh \
    --out-dir results \
    --sleep 1 \
    --cmn 0,1
```

Collect only CMN0:

```bash
./SE_Perf_CPU_SNF_CCG_NoRetry_BW_HNSMC_retry_pct.sh \
    --out-dir results \
    --sleep 1 \
    --cmn 0
```

Useful options:

| Option                              | Description                                     |
| ----------------------------------- | ----------------------------------------------- |
| `--sleep`                           | Sampling duration for each perf command         |
| `--cmn`                             | Collect CMN0, CMN1 or both (`0`, `1`, or `0,1`) |
| `--out-dir`                         | Output directory                                |
| `--run-only`                        | Collect raw perf data only                      |
| `--parse-only <raw_perf_stats.txt>` | Parse an existing raw log                       |

---

# Metrics Collected

## CPU PMU

Per-core PMU events:

* Event `0x60` — Read bandwidth
* Event `0x61` — Write bandwidth

Bandwidth calculation:

```
Bandwidth = Event Count × 32 Bytes / Elapsed Time
```

Per-CPU bandwidth is reported for every monitored core.

---

## SN-F Bandwidth

Watchpoints:

| Metric           | Watchpoint    |
| ---------------- | ------------- |
| Read             | `0x800002000` |
| Write (No Retry) | `0x80000e800` |

Bandwidth calculation:

```
Bandwidth = Watchpoint Count × 64 Bytes / Elapsed Time
```

---

## HNS Memory Controller

Counters collected:

* `hns_mc_reqs_local_sn`
* `hns_mc_retries_local_sn`
* `hns_mc_reqs_remote_sn`
* `hns_mc_retries_remote_sn`

The report computes:

* Total request bandwidth
* Retry bandwidth
* Effective bandwidth (excluding retries)
* Retry percentage

---

## CCG C2C

The script reports:

* Read bandwidth
* Clean write bandwidth
* Dirty write bandwidth

for both:

* `watchpoint_up`
* `watchpoint_down`

---

# Output Files

The following files are generated inside the output directory.

| File                         | Description             |
| ---------------------------- | ----------------------- |
| `raw_perf_stats.txt`         | Raw perf output         |
| `combined_perf_commands.txt` | Generated perf commands |
| `parsed_perf_stats.xlsx`     | Parsed Excel report     |

---

# Excel Workbook

The workbook contains the following worksheets:

* **RawData** – Raw parsed perf output
* **CPU_PMU** – Per-CPU bandwidth
* **SNF_NoRetry** – SN-F bandwidth
* **SNF_MC** – HNS MC requests, retries, retry percentage
* **CCG_C2C** – CCG bandwidth
* **Summary** – Chip-level bandwidth summary

---

# Re-parsing Existing Data

If `parsed_perf_stats.xlsx` is lost but `raw_perf_stats.txt` is available, regenerate the Excel report using:

```bash
./SE_Perf_CPU_SNF_CCG_NoRetry_BW_HNSMC_retry_pct.sh \
    --parse-only raw_perf_stats.txt
```

---

# Notes

* Default logs are written to the specified output directory.
* All generated files can be copied from the target using `scp`.
* Legacy scripts are archived under the `backup/` directory.
* CPU bandwidth is reported per CPU and summarized per chip.
* SN-F write bandwidth excludes retry traffic.
* HNS MC retry percentage is computed using the `_sn` request and retry counters.

