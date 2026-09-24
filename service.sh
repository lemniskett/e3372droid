#!/system/bin/sh

MODDIR=${0%/*}
case "$MODDIR" in
  /*) ;;
  *) MODDIR="$(pwd)/$MODDIR" ;;
esac

chmod 755 "$MODDIR/scripts/e3372.sh" "$MODDIR/bin/usb_modeswitch" 2>/dev/null || true

if command -v nohup >/dev/null 2>&1; then
  nohup "$MODDIR/scripts/e3372.sh" "$MODDIR" >>"$MODDIR/e3372.log" 2>&1 &
else
  "$MODDIR/scripts/e3372.sh" "$MODDIR" >>"$MODDIR/e3372.log" 2>&1 &
fi

exit 0
