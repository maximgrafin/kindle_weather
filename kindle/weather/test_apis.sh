#!/bin/sh
# /mnt/us/weather/test_apis.sh
# Deep-Sleep & Power Drain Diagnostic for Kindle (max77696)
#
# Usage:
#   sh /mnt/us/weather/test_apis.sh              # Inspect logs, current draw (mA), wakelocks, and RTC
#   sh /mnt/us/weather/test_apis.sh --test-sleep # Run a real 15s deep-sleep test (with Wi-Fi off) and log dmesg

REPORT="/mnt/us/weather/sleep_test.log"
mkdir -p /mnt/us/weather

run_diagnostics() {
  echo "=========================================="
  echo " Kindle Deep-Sleep & Battery Diagnostic"
  echo " Time: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "=========================================="

  echo ""
  echo "=== 1. Recent /mnt/us/weather/weather.log (last 30 lines) ==="
  if [ -f /mnt/us/weather/weather.log ]; then
    tail -n 30 /mnt/us/weather/weather.log
  else
    echo "  (no weather.log found)"
  fi

  echo ""
  echo "=== 2. Battery Current Draw & Fuel Gauge ==="
  if command -v gasgauge-info >/dev/null 2>&1; then
    echo "  gasgauge-info -c (capacity): $(gasgauge-info -c 2>/dev/null)"
    echo "  gasgauge-info -l (current):  $(gasgauge-info -l 2>/dev/null)"
    echo "  gasgauge-info -v (voltage):  $(gasgauge-info -v 2>/dev/null)"
  fi
  for f in /sys/class/power_supply/max77696-battery/*; do
    [ -f "$f" ] || continue
    bname=$(basename "$f")
    echo "  max77696-battery/$bname = $(cat "$f" 2>/dev/null)"
  done
  for f in /sys/class/power_supply/max77696-charger/*; do
    [ -f "$f" ] || continue
    cname=$(basename "$f")
    echo "  max77696-charger/$cname = $(cat "$f" 2>/dev/null)"
  done

  echo ""
  echo "=== 3. Running Processes & Services ==="
  initctl status framework 2>/dev/null || true
  initctl status powerd 2>/dev/null || true
  initctl status wifid 2>/dev/null || true
  initctl status cmd 2>/dev/null || true
  ps aux 2>/dev/null | grep -E "weather|rtcwake|sleep" | grep -v grep || ps | grep -E "weather|rtcwake|sleep" | grep -v grep || true

  echo ""
  echo "=== 4. Kernel Power & Wakelock State ==="
  for pf in /sys/power/*; do
    [ -f "$pf" ] || continue
    echo "  $pf: $(cat "$pf" 2>/dev/null | tr '\n' ' ')"
  done
  if [ -r /proc/wakelocks ]; then
    echo "  Active /proc/wakelocks:"
    awk '$6 > 0 {print "   ", $1, "active_since="$6}' /proc/wakelocks 2>/dev/null | head -n 20
  fi

  echo ""
  echo "=== 5. RTC Devices & Wakeup Capabilities ==="
  for rtc in /sys/class/rtc/rtc*; do
    [ -d "$rtc" ] || continue
    rname=$(basename "$rtc")
    name_val=$(cat "$rtc/name" 2>/dev/null)
    epoch_val=$(cat "$rtc/since_epoch" 2>/dev/null)
    alarm_val=$(cat "$rtc/wakealarm" 2>/dev/null)
    dev_wakeup=$(cat "$rtc/device/power/wakeup" 2>/dev/null)
    echo "  $rname ($name_val): since_epoch=$epoch_val wakealarm='$alarm_val' device/power/wakeup='$dev_wakeup'"
  done

  if [ "${1:-}" = "--test-sleep" ]; then
    echo ""
    echo "=== 6. Running 15-Second REAL Deep-Sleep Test (mem) ==="
    echo "  (Turning off Wi-Fi for ~17s, suspending to RAM, then reconnecting Wi-Fi...)"
    TMP_SLEEP_LOG="/mnt/us/weather/sleep_step.tmp"
    : > "$TMP_SLEEP_LOG"

    # Clear RTC wakealarms first
    for rtc in /sys/class/rtc/rtc0 /sys/class/rtc/rtc1; do
      if [ -w "${rtc}/wakealarm" ]; then
        echo 0 > "${rtc}/wakealarm" 2>/dev/null || true
      fi
    done

    # Set +15s alarm on both rtc0 and rtc1
    for rtc in /sys/class/rtc/rtc0 /sys/class/rtc/rtc1; do
      if [ -w "${rtc}/wakealarm" ]; then
        now_rtc=$(cat "${rtc}/since_epoch" 2>/dev/null)
        echo $((now_rtc + 15)) > "${rtc}/wakealarm" 2>&1 || echo "+15" > "${rtc}/wakealarm" 2>&1
        echo "  Armed $rtc/wakealarm => $(cat "${rtc}/wakealarm" 2>/dev/null) (target=$((now_rtc + 15)))" >> "$TMP_SLEEP_LOG"
      fi
    done

    lipc-set-prop com.lab126.cmd wirelessEnable 0 2>/dev/null || true
    ifconfig wlan0 down 2>/dev/null || true
    sleep 4

    t_before=$(date +%s)
    rtc_before=$(cat /sys/class/rtc/rtc0/since_epoch 2>/dev/null)
    echo "  Suspending via: echo mem > /sys/power/state (epoch=$t_before, rtc=$rtc_before)" >> "$TMP_SLEEP_LOG"
    sync

    # Write directly to /sys/power/state and capture any stderr error!
    if echo mem > /sys/power/state 2>> "$TMP_SLEEP_LOG"; then
      suspend_rc=0
    else
      suspend_rc=$?
    fi

    t_after=$(date +%s)
    rtc_after=$(cat /sys/class/rtc/rtc0/since_epoch 2>/dev/null)
    wall_diff=$((t_after - t_before))
    rtc_diff=$((rtc_after - rtc_before))

    echo "  Resumed! exit_code=$suspend_rc, wall_diff=${wall_diff}s, rtc_diff=${rtc_diff}s" >> "$TMP_SLEEP_LOG"

    # Clear wakealarms
    echo 0 > /sys/class/rtc/rtc0/wakealarm 2>/dev/null || true
    echo 0 > /sys/class/rtc/rtc1/wakealarm 2>/dev/null || true

    echo "" >> "$TMP_SLEEP_LOG"
    echo "=== 7. Kernel dmesg around suspend/resume ===" >> "$TMP_SLEEP_LOG"
    dmesg | tail -n 35 >> "$TMP_SLEEP_LOG"

    # Re-enable Wi-Fi and wait up to 20s for connection so SSH receives the output cleanly
    ifconfig wlan0 up 2>/dev/null || true
    lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null || true
    wpa_cli -i wlan0 reconnect >/dev/null 2>&1 || true

    w=0
    while [ "$w" -lt 20 ]; do
      if ping -c 1 -W 1 1.1.1.1 >/dev/null 2>&1 || ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; then
        break
      fi
      sleep 1
      w=$((w + 1))
    done

    cat "$TMP_SLEEP_LOG"
    rm -f "$TMP_SLEEP_LOG"
  fi

  echo ""
  echo "=========================================="
  echo " Diagnostic Complete (saved to $REPORT)"
  echo "=========================================="
}

run_diagnostics "${1:-}" 2>&1 | tee "$REPORT"
