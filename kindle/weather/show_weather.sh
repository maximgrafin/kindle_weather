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

generate_rotated_battery_pgm() {
  text="$1"
  out_pgm="$2"

  awk -v text="$text" '
  BEGIN {
    # 5x9 bitmap rows for digits 0-9, %, B, a, t, :, space
    g["0"] = "01110 10001 10001 10001 10001 10001 10001 10001 01110"
    g["1"] = "00100 01100 00100 00100 00100 00100 00100 00100 01110"
    g["2"] = "01110 10001 00001 00001 00010 00100 01000 10000 11111"
    g["3"] = "01110 10001 00001 00001 00110 00001 00001 10001 01110"
    g["4"] = "00010 00110 01010 10010 10010 11111 00010 00010 00010"
    g["5"] = "11111 10000 10000 11110 00001 00001 00001 10001 01110"
    g["6"] = "00110 01000 10000 11110 10001 10001 10001 10001 01110"
    g["7"] = "11111 00001 00010 00010 00100 00100 01000 01000 01000"
    g["8"] = "01110 10001 10001 10001 01110 10001 10001 10001 01110"
    g["9"] = "01110 10001 10001 10001 01111 00001 00001 00010 01100"
    g["%"] = "11001 11001 00010 00100 00100 01000 01000 10011 10011"
    g[":"] = "00000 00000 00110 00110 00000 00110 00110 00000 00000"
    g["B"] = "11110 10001 10001 10001 11110 10001 10001 10001 11110"
    g["a"] = "00000 00000 01110 00001 01111 10001 10001 10011 01101"
    g["t"] = "00100 00100 11110 00100 00100 00100 00100 00101 00010"
    g[" "] = "00000 00000 00000 00000 00000 00000 00000 00000 00000"

    len = length(text)
    char_w = 5
    char_h = 9
    gap = 2
    scale = 2

    unrot_w = len * (char_w + gap) - gap
    unrot_h = char_h

    for (i = 1; i <= len; i++) {
      ch = substr(text, i, 1)
      if (!(ch in g)) ch = " "
      split(g[ch], rows, " ")
      x_off = (i - 1) * (char_w + gap)
      for (r = 1; r <= char_h; r++) {
        row_str = rows[r]
        for (c = 1; c <= char_w; c++) {
          if (substr(row_str, c, 1) == "1") {
            pix[x_off + c - 1, r - 1] = 1
          }
        }
      }
    }

    # Rotate 90 degrees clockwise:
    # rot_w = unrot_h * scale, rot_h = unrot_w * scale
    rot_w = unrot_h * scale
    rot_h = unrot_w * scale

    printf "P5\n%d %d\n255\n", rot_w, rot_h
    for (ry = 0; ry < rot_h; ry++) {
      ux = int(ry / scale)
      for (rx = 0; rx < rot_w; rx++) {
        uy = unrot_h - 1 - int(rx / scale)
        val = ((ux, uy) in pix) ? 68 : 255
        printf "%c", val
      }
    }
  }' > "$out_pgm"
}

render_screen() {
  turn_off_frontlight

  if [ ! -f "$IMG_PATH" ]; then
    log "ERROR: No weather-90.png available to display"
    return 1
  fi

  batt=$(get_battery_percent)
  bb=$(printf "%02d" "$batt" 2>/dev/null || echo "$batt")
  hhmm=$(TZ="CET-1CEST,M3.5.0,M10.5.0/3" date '+%H%M')
  status_code="${bb}${hhmm}"
  batt_pgm="${WEATHER_DIR}/batt.pgm"

  if command -v fbink >/dev/null 2>&1; then
    fbink -c -g "file=$IMG_PATH"
    generate_rotated_battery_pgm "$status_code" "$batt_pgm"
    if [ -s "$batt_pgm" ]; then
      # x=15 (footer line along left edge of weather-90.png), y=42 (aligned with Hero card edge)
      fbink -g "file=${batt_pgm},x=15,y=42"
    else
      fbink -x 0 -y 2 "$status_code"
    fi
  else
    eips -c
    eips -f -g "$IMG_PATH"
    eips 0 2 "$status_code"
  fi

  log "Rendered weather-90.png with status ${status_code} (battery ${batt}%, time ${hhmm})"
}

download_weather_image
render_screen
