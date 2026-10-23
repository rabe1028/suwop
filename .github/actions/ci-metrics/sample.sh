#!/usr/bin/env bash
# Background resource sampler for CI jobs. Records raw counters only; deltas,
# per-step attribution and reports come from scripts/ci_metrics.py.
#   sample.sh start DIR   start samplers that write into DIR
#   sample.sh stop DIR    stop them and record final disk usage
set -euo pipefail
MODE="$1"
DIR="$2"
INTERVAL="${CI_METRICS_INTERVAL:-2}"

linux_counters() {
    local cpu disk_read=0 disk_write=0 rx=0 tx=0 name rd wr r t mem_avail swap_total swap_free
    cpu="$(awk '/^cpu /{print $2","$3","$4","$5","$6","$7","$8","$9; exit}' /proc/stat)"
    # Whole devices only; partitions would double-count.
    while read -r _ _ name _ _ rd _ _ _ wr _; do
        if [[ "$name" =~ ^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|nvme[0-9]+n[0-9]+)$ ]]; then
            disk_read=$((disk_read + rd * 512))
            disk_write=$((disk_write + wr * 512))
        fi
    done < /proc/diskstats
    while IFS=: read -r name rest; do
        name="${name// /}"
        [[ "$name" == lo || -z "$rest" || "$name" == Inter* || "$name" == face* ]] && continue
        read -r r _ _ _ _ _ _ _ t _ <<< "$rest"
        rx=$((rx + r))
        tx=$((tx + t))
    done < <(tail -n +3 /proc/net/dev)
    mem_avail="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"
    swap_total="$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)"
    swap_free="$(awk '/^SwapFree:/{print $2}' /proc/meminfo)"
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$(date +%s)" "$cpu" "$mem_avail" \
        "$((swap_total - swap_free))" "$disk_read" "$disk_write" "$rx" "$tx" \
        "$(cut -d' ' -f1 /proc/loadavg)"
}

start() {
    mkdir -p "$DIR"
    {
        echo "os=$(uname -s)"
        echo "arch=$(uname -m)"
        echo "job=${GITHUB_JOB:-local}"
        echo "runner=${RUNNER_NAME:-local}"
        echo "image=${ImageOS:-unknown}-${ImageVersion:-unknown}"
        echo "interval=$INTERVAL"
        echo "start_epoch=$(date +%s)"
        # top prints local wall time; this offset converts it to UTC epoch seconds.
        echo "utc_offset=$(date +%z)"
        if [[ "$(uname -s)" == Darwin ]]; then
            echo "cpus=$(sysctl -n hw.ncpu)"
            echo "mem_bytes=$(sysctl -n hw.memsize)"
        else
            echo "cpus=$(nproc)"
            echo "mem_bytes=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) * 1024 ))"
        fi
    } > "$DIR/system.txt"
    if [[ "$(uname -s)" == Darwin ]]; then
        # Each frame has CPU, PhysMem, VM swap, Networks and Disks counters plus
        # the busiest processes. top's first frame is not interval-based.
        nohup top -l 0 -s "$INTERVAL" -n 8 -o cpu -stats pid,command,cpu,rsize,threads \
            > "$DIR/top.log" 2>&1 &
        echo $! >> "$DIR/pids"
    else
        echo "time,user,nice,system,idle,iowait,irq,softirq,steal,mem_avail_kb,swap_used_kb,disk_read_bytes,disk_write_bytes,net_rx_bytes,net_tx_bytes,load1" \
            > "$DIR/samples.csv"
        nohup bash -c "while true; do bash \"$0\" counters \"$DIR\" >> \"$DIR/samples.csv\" || true; sleep $INTERVAL; done" \
            > /dev/null 2>&1 &
        echo $! >> "$DIR/pids"
        if command -v top > /dev/null; then
            # The second frame of each run covers the last 10 seconds; keep its
            # header and the busiest processes.
            nohup bash -c "while true; do echo @\$(date +%s); top -b -c -w 300 -n 2 -d 10 -o %CPU | awk '/^top -/{f++; n=-8} f == 2 {n++; if (n <= 8) print}'; done" \
                > "$DIR/top.log" 2>&1 &
            echo $! >> "$DIR/pids"
        fi
    fi
    nohup bash -c "while true; do echo \"\$(date +%s) \$(df -Pk \"\${GITHUB_WORKSPACE:-.}\" | tail -1)\"; sleep 30; done" \
        > "$DIR/disk.log" 2>&1 &
    echo $! >> "$DIR/pids"
}

stop() {
    if [[ -f "$DIR/pids" ]]; then
        while read -r pid; do
            pkill -P "$pid" 2> /dev/null || true
            kill "$pid" 2> /dev/null || true
        done < "$DIR/pids"
    fi
    echo "$(date +%s) $(df -Pk "${GITHUB_WORKSPACE:-.}" | tail -1)" >> "$DIR/disk.log"
    date +%s > "$DIR/stopped"
}

case "$MODE" in
    start) start ;;
    stop) stop ;;
    counters) linux_counters ;;
    *) echo "Usage: sample.sh start|stop DIR" >&2; exit 1 ;;
esac
