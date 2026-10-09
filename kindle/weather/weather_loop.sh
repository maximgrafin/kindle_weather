#!/bin/sh
# /mnt/us/weather/weather_loop.sh
# Main power & schedule loop for Kindle Weather Widget:
# 1. Stops Kindle UI/powerd and turns off the frontlight.
# 2. Updates the screen once per hour (aligned to :00) via show_weather.sh.
# 3. On battery: turns off Wi-Fi and enters kernel RTC deep sleep until next :00.
# 4. On charger: keeps Wi-Fi ON and stays awake (for SSH access), still updating once/hour.
# 5. When charger is unplugged: waits 5 minutes before turning off Wi-Fi and sleeping.
#
# Usage:
#   /mnt/us/weather/weather_loop.sh          # Run loop
#   /mnt/us/weather/weather_loop.sh --stop   # Stop loop and restore normal Kindle UI

WEATHER_DIR="/mnt/us/weather"
SHOW_SCRIPT="${WEATHER_DIR}/show_weather.sh"
PID_FILE="${WEATHER_DIR}/weather_loop.pid"
LOG_FILE="${WEATHER_DIR}/weather.log"
UNPLUG_GRACE_SECONDS=300

mkdir -p "$WEATHER_DIR"

log() {
  # Keep log file around 1000 lines so it provides plenty of history without filling storage
  if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE" | tr -dc '0-9')" -gt 1200 ]; then
    tail -n 1000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv -f "${LOG_FILE}.tmp" "$LOG_FILE"
  fi
  echo "$(date '+%Y-%m-%d %H:%M:%S') [weather_loop] $*" >> "$LOG_FILE"
}

turn_off_frontlight() {
  lipc-set-prop com.lab126.powerd flIntensity 0 2>/dev/null || true
  for bl in \
    /sys/class/backlight/*/brightness \
    /sys/devices/platform/imx-i2c.0/i2c-0/0-003c/max77696-bl.0/backlight/max77696-bl/brightness \
    /sys/devices/system/fl_tps6116x/fl_tps6116x0/fl_intensity
  do
    if [ -w "$bl" ]; then
      echo 0 > "$bl" 2>/dev/null || true
    fi
  done
}

is_charging() {
  # 1. Check sysfs USB/charger online flags (works even when powerd is stopped)
  for online in \
    /sys/class/power_supply/*usb*/online \
    /sys/class/power_supply/*charger*/online \
    /sys/class/power_supply/*ac*/online \
    /sys/devices/system/yoshi_battery/yoshi_battery0/battery_CAR
  do
    if [ -r "$online" ]; then
      val=$(tr -dc '0-9' < "$online" 2>/dev/null)
      if [ "$val" = "1" ]; then
        return 0
      fi
    fi
  done

  # 2. Check battery status string (Charging while plugged in)
  for status_file in /sys/class/power_supply/*battery*/status /sys/class/power_supply/*/status; do
    if [ -r "$status_file" ]; then
      st=$(cat "$status_file" 2>/dev/null)
      case "$st" in
        Charging*)
          return 0
          ;;
      esac
    fi
  done

  # 3. Fallback to lipc if powerd is running
  if command -v lipc-get-prop >/dev/null 2>&1; then
    if [ "$(lipc-get-prop com.lab126.powerd isCharging 2>/dev/null)" = "1" ]; then
      return 0
    fi
  fi

  return 1
}

enable_wifi() {
  lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null || true
  ifconfig wlan0 up 2>/dev/null || true
  wpa_cli -i wlan0 reconnect >/dev/null 2>&1 || true
}

disable_wifi() {
  lipc-set-prop com.lab126.cmd wirelessEnable 0 2>/dev/null || true
}

wait_for_wifi() {
  enable_wifi
  elapsed=0
  max_wait=40
  while [ "$elapsed" -lt "$max_wait" ]; do
    if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 || ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
      log "Wi-Fi connected after ${elapsed}s"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  log "WARN: Wi-Fi did not confirm internet within ${max_wait}s; proceeding anyway"
  return 1
}

seconds_until_next_hour() {
  now=$(date +%s)
  # Wake 5 seconds past :00 so the system clock is guaranteed to be in the new hour
  rem=$((3605 - (now % 3600)))
  if [ "$rem" -lt 45 ]; then
    rem=$((rem + 3600))
  fi
  echo "$rem"
}

rtc_deep_sleep() {
  sleep_secs="$1"
  log "Entering deep sleep for ${sleep_secs}s (until next :00)"

  # Sync filesystems before suspend
  sync

  if command -v rtcwake >/dev/null 2>&1; then
    rtcwake -d /dev/rtc0 -m mem -s "$sleep_secs" >> "$LOG_FILE" 2>&1 && return 0
    rtcwake -m mem -s "$sleep_secs" >> "$LOG_FILE" 2>&1 && return 0
  fi

  # Direct sysfs RTC wakealarm fallback
  for rtc in /sys/class/rtc/rtc0 /sys/class/rtc/rtc1; do
    if [ -w "${rtc}/wakealarm" ]; then
      echo 0 > "${rtc}/wakealarm" 2>/dev/null || true
      if [ -r "${rtc}/since_epoch" ]; then
        now_rtc=$(cat "${rtc}/since_epoch" 2>/dev/null)
        echo $((now_rtc + sleep_secs)) > "${rtc}/wakealarm" 2>/dev/null || echo "+${sleep_secs}" > "${rtc}/wakealarm" 2>/dev/null
      else
        echo "+${sleep_secs}" > "${rtc}/wakealarm" 2>/dev/null
      fi
    fi
  done

  echo mem > /sys/power/state 2>/dev/null || sleep "$sleep_secs"
}

stop_loop_and_restore_ui() {
  log "Stopping weather_loop and restoring Kindle UI..."
  if [ -f "$PID_FILE" ]; then
    old_pid=$(cat "$PID_FILE" 2>/dev/null)
    rm -f "$PID_FILE"
    if [ -n "$old_pid" ] && [ "$old_pid" != "$$" ]; then
      kill "$old_pid" 2>/dev/null || true
    fi
  fi
  enable_wifi
  start powerd 2>/dev/null || /etc/init.d/powerd start 2>/dev/null || true
  start framework 2>/dev/null || /etc/init.d/framework start 2>/dev/null || true
  exit 0
}

if [ "${1:-}" = "--stop" ]; then
  stop_loop_and_restore_ui
fi

# Prevent duplicate loop instances
if [ -f "$PID_FILE" ]; then
  old_pid=$(cat "$PID_FILE" 2>/dev/null)
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    log "Killing previous weather_loop instance (PID $old_pid)"
    kill "$old_pid" 2>/dev/null || true
    sleep 1
  fi
fi
echo "$$" > "$PID_FILE"
trap 'rm -f "$PID_FILE"; exit 0' INT TERM EXIT

log "Starting Kindle Weather Loop (PID $$)"

# 1. Turn off frontlight & stop native UI/powerd so lockscreen never overwrites eips
turn_off_frontlight
stop framework 2>/dev/null || /etc/init.d/framework stop 2>/dev/null || true
stop powerd 2>/dev/null || /etc/init.d/powerd stop 2>/dev/null || true
turn_off_frontlight

last_updated_hour=""
unplug_elapsed=0

while true; do
  turn_off_frontlight
  current_hour=$(date '+%Y-%m-%d-%H')

  # Update screen immediately on first start or whenever a new hour (:00) begins
  if [ "$current_hour" != "$last_updated_hour" ]; then
    wait_for_wifi
    sh "$SHOW_SCRIPT"
    last_updated_hour=$(date '+%Y-%m-%d-%H')
  fi

  if is_charging; then
    # Charger is plugged in: keep Wi-Fi ON for SSH and stay awake
    if [ "$unplug_elapsed" -gt 0 ]; then
      log "Charger re-attached; canceling sleep timer and keeping Wi-Fi on"
    fi
    unplug_elapsed=0
    enable_wifi
    sleep 5
    continue
  fi

  # Charger is NOT plugged in:
  # If we were previously awake on charger (or just booted/unplugged), wait 5 minutes before sleeping.
  if [ "$unplug_elapsed" -lt "$UNPLUG_GRACE_SECONDS" ]; then
    if [ "$unplug_elapsed" -eq 0 ]; then
      log "On battery: waiting ${UNPLUG_GRACE_SECONDS}s (5 min) grace window before deep sleep (SSH stays active)"
      enable_wifi
    fi
    sleep 5
    unplug_elapsed=$((unplug_elapsed + 5))
    continue
  fi

  # 5-minute grace window has elapsed and charger is still detached:
  # Turn off Wi-Fi and deep-sleep until the top of the next hour (:00)
  disable_wifi
  sleep 2

  sleep_duration=$(seconds_until_next_hour)
  rtc_deep_sleep "$sleep_duration"

  # Kernel just woke up (either from RTC at :00, or early because USB cable was plugged in!)
  turn_off_frontlight
  if is_charging; then
    log "Woke up because charger was connected; enabling Wi-Fi and staying awake"
    unplug_elapsed=0
    enable_wifi
  else
    log "Woke up from RTC alarm for hourly update"
    # Force an update on this RTC wakeup and skip the 5-minute grace window afterward
    last_updated_hour=""
    unplug_elapsed="$UNPLUG_GRACE_SECONDS"
  fi
done
