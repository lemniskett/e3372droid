#!/system/bin/sh

if type ui_print >/dev/null 2>&1; then
  ui_print "e3372droid: Huawei E3372h HiLink for Android 16"
fi

if type set_perm_recursive >/dev/null 2>&1; then
  set_perm_recursive "$MODPATH" 0 0 0755 0644
fi

if type set_perm >/dev/null 2>&1; then
  set_perm "$MODPATH/service.sh" 0 0 0755
  set_perm "$MODPATH/customize.sh" 0 0 0755
  set_perm "$MODPATH/scripts/e3372.sh" 0 0 0755
  set_perm "$MODPATH/bin/usb_modeswitch" 0 0 0755
fi
