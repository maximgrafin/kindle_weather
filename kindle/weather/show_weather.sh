#!/bin/sh
# /mnt/us/weather/show_weather.sh
# Downloads the latest 90°-rotated weather image (1072x1448), renders it on the
# Kindle E-Ink framebuffer, and overlays a small battery percentage indicator.

WEATHER_DIR="/mnt/us/weather"
IMG_URL="https://maximgrafin.github.io/kindle_weather/weather-90.png"
IMG_PATH="${WEATHER_DIR}/weather-90.png"
TMP_PATH="${WEATHER_DIR}/weather-90.png.tmp"
LOG_FILE="${WEATHER_DIR}/weather.log"

mkdir -p "$WEATHER_DIR"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [show_weather] $*" >> "$LOG_FILE"
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

get_battery_percent() {
  pct=""
  if command -v gasgauge-info >/dev/null 2>&1; then
    pct=$(gasgauge-info -c 2>/dev/null | tr -dc '0-9')
  fi
  if [ -z "$pct" ]; then
    for cap in \
      /sys/class/power_supply/*battery*/capacity \
      /sys/class/power_supply/bd71827_bat/capacity \
      /sys/class/power_supply/max77696-battery/capacity \
      /sys/devices/system/yoshi_battery/yoshi_battery0/battery_capacity
    do
      if [ -r "$cap" ]; then
        pct=$(tr -dc '0-9' < "$cap" 2>/dev/null)
        [ -n "$pct" ] && break
      fi
    done
  fi
  if [ -z "$pct" ] && command -v lipc-get-prop >/dev/null 2>&1; then
    pct=$(lipc-get-prop com.lab126.powerd battLevel 2>/dev/null | tr -dc '0-9')
  fi
  echo "${pct:-?}"
}

download_weather_image() {
  url_with_ts="${IMG_URL}?ts=$(date +%s)"
  rm -f "$TMP_PATH"

  if command -v curl >/dev/null 2>&1; then
    curl -k -fsSL --connect-timeout 15 --max-time 30 "$url_with_ts" -o "$TMP_PATH" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget --no-check-certificate -q -T 25 -O "$TMP_PATH" "$url_with_ts" 2>/dev/null
  else
    log "ERROR: Neither curl nor wget found"
    return 1
  fi

  # Verify downloaded file exists and is at least 10 KB (valid PNG)
  if [ -s "$TMP_PATH" ]; then
    file_size=$(wc -c < "$TMP_PATH" | tr -dc '0-9')
    if [ "${file_size:-0}" -gt 10000 ]; then
      mv -f "$TMP_PATH" "$IMG_PATH"
      log "Downloaded fresh weather-90.png (${file_size} bytes)"
      return 0
    fi
  fi

  rm -f "$TMP_PATH"
  log "WARN: Download failed or incomplete; keeping previous image if available"
  return 1
}

render_screen() {
  turn_off_frontlight

  if [ -f "$IMG_PATH" ]; then
    eips -c
    eips -f -g "$IMG_PATH"
  else
    log "ERROR: No weather-90.png available to display"
    return 1
  fi

  batt=$(get_battery_percent)
  # Draw small battery percentage in top-left margin (col 0, row 0)
  eips 0 0 "${batt}%"
  log "Rendered weather-90.png with battery ${batt}%"
}

download_weather_image
render_screen
