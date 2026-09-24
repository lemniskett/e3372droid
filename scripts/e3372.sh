#!/system/bin/sh

export PATH="/system/bin:/system/xbin:/vendor/bin:$PATH"
trap '' HUP

MODDIR=$1
if [ -z "$MODDIR" ]; then
  MODDIR=${0%/*}
  MODDIR=${MODDIR%/*}
fi

LOG="$MODDIR/e3372.log"
BIN="$MODDIR/bin/usb_modeswitch"
PIDFILE="$MODDIR/e3372.pid"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"
}

if [ -f "$PIDFILE" ]; then
  old=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "$old" ] && [ -d "/proc/$old" ]; then
    exit 0
  fi
fi
echo $$ >"$PIDFILE"

if [ -f "$LOG" ]; then
  sz=$(wc -c <"$LOG" 2>/dev/null)
  if [ -n "$sz" ] && [ "$sz" -gt 262144 ]; then
    mv "$LOG" "$LOG.old"
  fi
fi

log_rndis() {
  if [ -d /sys/bus/usb/drivers/rndis_host ]; then
    log "rndis_host: sysfs driver present"
    return
  fi
  if [ -r /proc/config.gz ]; then
    line=$(gzip -dc /proc/config.gz 2>/dev/null | grep '^CONFIG_USB_NET_RNDIS_HOST=')
    if [ -n "$line" ]; then
      log "rndis_host: $line"
      return
    fi
  fi
  if dmesg 2>/dev/null | grep -q rndis_host; then
    log "rndis_host: mentioned in dmesg"
    return
  fi
  log "rndis_host: not visible in sysfs, config.gz, or dmesg"
}

usb_snapshot() {
  for d in /sys/bus/usb/devices/[0-9]*; do
    [ -f "$d/busnum" ] || continue
    [ -f "$d/idVendor" ] || continue
    echo "$(cat "$d/idVendor"):$(cat "$d/idProduct")"
  done | sort | tr '\n' ' '
}

find_dev() {
  want=$1
  for d in /sys/bus/usb/devices/[0-9]*; do
    [ -f "$d/busnum" ] || continue
    [ "$(cat "$d/idVendor" 2>/dev/null)" = "12d1" ] || continue
    [ "$(cat "$d/idProduct" 2>/dev/null)" = "$want" ] || continue
    echo "$d"
    return 0
  done
  return 1
}

find_storage() {
  for d in /sys/bus/usb/devices/[0-9]*; do
    [ -f "$d/busnum" ] || continue
    [ "$(cat "$d/idVendor" 2>/dev/null)" = "12d1" ] || continue
    pid=$(cat "$d/idProduct" 2>/dev/null)
    if [ "$pid" = "1f01" ] || [ "$pid" = "14fe" ]; then
      echo "$d"
      return 0
    fi
  done
  return 1
}

find_net() {
  dev=$1
  for p in "$dev"/*/net/* "$dev"/net/*; do
    [ -e "$p" ] || continue
    basename "$p"
    return 0
  done
  return 1
}

message_for() {
  cfg="$MODDIR/config/12d1.$1"
  [ -f "$cfg" ] || return 1
  sed -n 's/^MessageContent=//p' "$cfg" | head -n 1
}

free_eth() {
  n=0
  while [ -d "/sys/class/net/eth$n" ]; do
    n=$((n + 1))
    if [ "$n" -gt 15 ]; then
      return 1
    fi
  done
  echo "eth$n"
}

regex_blocks_eth() {
  line=$(logcat -d -s EthernetTracker:D EthernetTracker:I 2>/dev/null | grep "Interface match regexp" | tail -n 1)
  if [ -z "$line" ]; then
    line=$(dumpsys ethernet 2>/dev/null | grep -e "mIfaceMatch" -e "Interface match regexp" | tail -n 1)
  fi
  if [ -z "$line" ]; then
    log "ethernet regex not in logcat or dumpsys, renaming to ethN anyway"
    return 1
  fi
  log "ethernet matcher: $line"
  case "$line" in
    *eth*) return 1 ;;
  esac
  log "ethernet regex does not include eth, stopping"
  return 0
}

has_ip() {
  ip -4 addr show dev "$1" 2>/dev/null | grep -q 'inet 192\.168\.8\.'
}

is_default() {
  route=$(ip route get 8.8.8.8 2>/dev/null) || return 1
  case "$route" in
    *"dev $1 "*|*"dev $1") return 0 ;;
  esac
  return 1
}

switch_storage() {
  devdir=$1
  pid=$(cat "$devdir/idProduct")
  bus=$(cat "$devdir/busnum")
  dev=$(cat "$devdir/devnum")
  key="$bus:$dev:$pid"
  now=$(date +%s)
  if [ "$key" = "$last_key" ] && [ $((now - last_ts)) -lt 15 ]; then
    return 0
  fi
  msg=$(message_for "$pid") || {
    log "no HiLink config for 12d1:$pid"
    return 1
  }
  log "switching 12d1:$pid bus $bus dev $dev toward 12d1:14dc"
  if "$BIN" -b "$bus" -g "$dev" -v 0x12d1 -p "0x$pid" -M "$msg"; then
    log "modeswitch sent for 12d1:$pid"
  else
    log "modeswitch failed for 12d1:$pid"
  fi
  last_key=$key
  last_ts=$now
}

sdk=$(getprop ro.build.version.sdk)
log "sdk=$sdk"
if [ "$sdk" != "36" ]; then
  log "refusing: Android 16 (sdk 36) required"
  exit 1
fi

if [ ! -x "$BIN" ]; then
  log "missing $BIN"
  exit 1
fi

log_rndis
modprobe rndis_host 2>/dev/null || true

last_ids=""
last_key=""
last_ts=0
no_iface=0
renamed=""
regex_checked=0
online=0
wait_logged=0

while true; do
  ids=$(usb_snapshot)
  if [ "$ids" != "$last_ids" ]; then
    log "usb: ${ids:-none}"
    last_ids=$ids
  fi

  hilink=$(find_dev 14dc || true)
  if [ -z "$hilink" ]; then
    storage=$(find_storage || true)
    if [ -n "$storage" ]; then
      switch_storage "$storage"
    fi
    no_iface=0
    renamed=""
    regex_checked=0
    online=0
    wait_logged=0
    sleep 3
    continue
  fi

  iface=$(find_net "$hilink" || true)
  if [ -z "$iface" ]; then
    no_iface=$((no_iface + 1))
    if [ "$no_iface" -ge 7 ]; then
      log "12d1:14dc has no net interface. Kernel has no CONFIG_USB_NET_RNDIS_HOST. A module built for another kernel will not load."
      exit 1
    fi
    sleep 3
    continue
  fi
  no_iface=0

  if [ "$regex_checked" != "1" ]; then
    if regex_blocks_eth; then
      exit 1
    fi
    regex_checked=1
  fi

  case "$iface" in
    eth*)
      renamed=$iface
      ip link set dev "$renamed" up >>"$LOG" 2>&1 || true
      ;;
    *)
      if [ -z "$renamed" ] || [ ! -d "/sys/class/net/$renamed" ]; then
        renamed=$(free_eth) || {
          log "no free ethN"
          exit 1
        }
        log "rename $iface to $renamed"
        ip link set dev "$iface" down >>"$LOG" 2>&1 || true
        if ! ip link set dev "$iface" name "$renamed" >>"$LOG" 2>&1; then
          log "rename $iface to $renamed failed"
          renamed=""
          sleep 3
          continue
        fi
        ip link set dev "$renamed" up >>"$LOG" 2>&1 || true
      fi
      ;;
  esac

  if has_ip "$renamed" && is_default "$renamed"; then
    if [ "$online" != "1" ]; then
      addr=$(ip -4 addr show dev "$renamed" 2>/dev/null | sed -n 's/.*inet /inet /p' | head -n 1)
      log "online $renamed $addr"
      online=1
    fi
    wait_logged=0
  else
    online=0
    if [ "$wait_logged" != "1" ]; then
      wait_n=0
      while [ "$wait_n" -lt 15 ]; do
        has_ip "$renamed" && is_default "$renamed" && break
        wait_n=$((wait_n + 1))
        sleep 3
      done
      if has_ip "$renamed" && is_default "$renamed"; then
        addr=$(ip -4 addr show dev "$renamed" 2>/dev/null | sed -n 's/.*inet /inet /p' | head -n 1)
        log "online $renamed $addr"
        online=1
      else
        log "waiting: $renamed has no 192.168.8 address or is not the default route"
        ip -4 addr show dev "$renamed" >>"$LOG" 2>&1 || true
        ip route get 8.8.8.8 >>"$LOG" 2>&1 || true
        wait_logged=1
      fi
    fi
  fi

  sleep 5
done
