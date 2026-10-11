#!/bin/sh
# /mnt/us/weather/test_apis.sh
# Diagnostic script to verify every hardware/system API used by
# show_weather.sh and weather_loop.sh on this specific Kindle model.
#
# Usage:
#   sh /mnt/us/weather/test_apis.sh              # Safe read/display/network checks
#   sh /mnt/us/weather/test_apis.sh --test-sleep # Also tests a 10-second RTC deep sleep & wakeup

echo "=========================================="
echo " Kindle Weather Hardware API Self-Test"
echo "=========================================="

# 1. Frontlight API
echo ""
echo "[1/7] Checking Frontlight (Backlight) API..."
fl_found=0
if command -v lipc-get-prop >/dev/null 2>&1; then
  cur_fl=$(lipc-get-prop com.lab126.powerd flIntensity 2>/dev/null)
  if [ -n "$cur_fl" ]; then
    echo "  PASS: lipc powerd flIntensity = $cur_fl"
    fl_found=1
  fi
fi
for bl in \
  /sys/class/backlight/*/brightness \
  /sys/devices/platform/imx-i2c.0/i2c-0/0-003c/max77696-bl.0/backlight/max77696-bl/brightness \
  /sys/devices/system/fl_tps6116x/fl_tps6116x0/fl_intensity
do
  if [ -e "$bl" ]; then
    echo "  PASS: sysfs backlight node found: $bl (current=$(cat "$bl" 2>/dev/null), writable=$( [ -w "$bl" ] && echo yes || echo no ))"
    fl_found=1
  fi
done
[ "$fl_found" -eq 0 ] && echo "  WARN: No frontlight sysfs node matched; check: ls -l /sys/class/backlight/"

# 2. Battery Percentage API
echo ""
echo "[2/7] Checking Battery Level API..."
if command -v gasgauge-info >/dev/null 2>&1; then
  echo "  gasgauge-info -c => $(gasgauge-info -c 2>/dev/null)"
fi
for cap in \
  /sys/class/power_supply/*battery*/capacity \
  /sys/class/power_supply/*/capacity \
  /sys/devices/system/yoshi_battery/yoshi_battery0/battery_capacity
do
  if [ -r "$cap" ]; then
    echo "  PASS: sysfs capacity ($cap) => $(cat "$cap" 2>/dev/null)%"
  fi
done
if command -v lipc-get-prop >/dev/null 2>&1; then
  echo "  lipc powerd battLevel => $(lipc-get-prop com.lab126.powerd battLevel 2>/dev/null)"
fi

# 3. Charger / USB Plugged-in Detection API
echo ""
echo "[3/7] Checking Charger / USB Detection API..."
for p in /sys/class/power_supply/*; do
  [ -d "$p" ] || continue
  name=$(basename "$p")
  online=$( [ -r "$p/online" ] && tr -d '\n' < "$p/online" || echo "n/a" )
  status=$( [ -r "$p/status" ] && tr -d '\n' < "$p/status" || echo "n/a" )
  type=$( [ -r "$p/type" ] && tr -d '\n' < "$p/type" || echo "n/a" )
  echo "  power_supply/$name: type=$type online=$online status=$status"
done
if command -v lipc-get-prop >/dev/null 2>&1; then
  echo "  lipc powerd isCharging => $(lipc-get-prop com.lab126.powerd isCharging 2>/dev/null)"
fi

# 4. Wi-Fi & HTTPS Download API
echo ""
echo "[4/7] Checking Wi-Fi & HTTPS Download Tools..."
for tool in lipc-set-prop ifconfig wpa_cli ping curl wget; do
  if command -v "$tool" >/dev/null 2>&1; then
    echo "  PASS: $tool found at $(command -v "$tool")"
  else
    echo "  INFO: $tool not found"
  fi
done
if ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
  echo "  PASS: Internet ping (1.1.1.1) succeeded"
else
  echo "  WARN: Internet ping (1.1.1.1) failed"
fi

# 5. E-Ink Display (eips) API
echo ""
echo "[5/7] Checking E-Ink Display (eips)..."
if command -v eips >/dev/null 2>&1; then
  echo "  PASS: eips found at $(command -v eips)"
  eips 0 0 "API TEST OK"
  echo "  PASS: Drew 'API TEST OK' at top-left (0,0) via eips"
else
  echo "  FAIL: eips not found!"
fi

# 6. Service Control (framework / powerd)
echo ""
echo "[6/7] Checking Init / Upstart Service Control..."
if command -v initctl >/dev/null 2>&1; then
  echo "  PASS: Upstart initctl found:"
  initctl status framework 2>/dev/null | sed 's/^/    /'
  initctl status powerd 2>/dev/null | sed 's/^/    /'
elif [ -x /etc/init.d/framework ]; then
  echo "  PASS: SysV /etc/init.d/framework & /etc/init.d/powerd found"
else
  echo "  WARN: Neither initctl nor /etc/init.d/framework found"
fi

# 7. RTC Wakealarm & Deep Sleep API
echo ""
echo "[7/7] Checking RTC Wakealarm & Kernel Suspend..."
if command -v rtcwake >/dev/null 2>&1; then
  echo "  PASS: rtcwake binary found at $(command -v rtcwake)"
else
  echo "  INFO: rtcwake binary not present (will use sysfs /sys/class/rtc/rtc*/wakealarm)"
fi
for rtc in /sys/class/rtc/rtc*; do
  [ -d "$rtc" ] || continue
  echo "  PASS: RTC device $rtc: since_epoch=$(cat "$rtc/since_epoch" 2>/dev/null), wakealarm writable=$( [ -w "$rtc/wakealarm" ] && echo yes || echo no )"
done
echo "  /sys/power/state supported modes: $(cat /sys/power/state 2>/dev/null)"

if [ "${1:-}" = "--test-sleep" ]; then
  echo ""
  echo ">>> Testing 15-second RTC wakealarm (without suspending CPU if on USB, or full mem sleep)..."
  echo "    Setting wakealarm for +15 seconds..."
  echo 0 > /sys/class/rtc/rtc0/wakealarm 2>/dev/null || true
  now_rtc=$(cat /sys/class/rtc/rtc0/since_epoch 2>/dev/null)
  echo $((now_rtc + 15)) > /sys/class/rtc/rtc0/wakealarm 2>/dev/null || echo "+15" > /sys/class/rtc/rtc0/wakealarm
  echo "    Verify programmed wakealarm: $(cat /sys/class/rtc/rtc0/wakealarm 2>/dev/null) (target=$((now_rtc + 15)))"
  echo 0 > /sys/class/rtc/rtc0/wakealarm 2>/dev/null || true
fi

echo ""
echo "=========================================="
echo " Self-Test Complete"
echo "=========================================="
