# e3372droid

KernelSU module for a Huawei E3372h in HiLink mode on Android 16. The stick boots as a virtual CD. The module sends the HiLink switch so the kernel can create an RNDIS interface, then renames that interface to a free `ethN`. Android 16 `EthernetTracker` only tracks names that match `eth`, runs DHCP from `192.168.8.1`, and can set the default network.

The phone gets a `192.168.8.x` address. The stick still does NAT. Signal, SMS, and APN stay on `http://192.168.8.1`.

## Install

The module zip is [e3372droid.zip](e3372droid.zip) in the repo root. Install that file in the KernelSU app, then reboot.

Rebuild it from the repo root with:

```sh
zip -r e3372droid.zip module.prop customize.sh service.sh scripts config bin
```

The zip root must contain `module.prop`. `service.sh` starts `scripts/e3372.sh` in the background. The log is `/data/adb/modules/e3372droid/e3372.log`.

```sh
su -c cat /data/adb/modules/e3372droid/e3372.log
```

A line like `online eth0 inet 192.168.8.x/24` means the tracker took the link.

Use a powered USB OTG adapter. The E3372 often brown-outs on an unpowered phone port. That is a power problem, not a software one.

## If the log says rndis_host is missing

`12d1:14dc has no net interface` means this kernel was built without `CONFIG_USB_NET_RNDIS_HOST`. The module stops there. A `.ko` built for another kernel will not load (vermagic). The same log line is written when `rndis_host` is absent from sysfs, `/proc/config.gz`, and `dmesg`.

If the log says the ethernet regex does not include `eth`, this phone's `EthernetTracker` will ignore the renamed port. The module stops. An overlay for that regex is not part of this module.

The module also exits immediately when `ro.build.version.sdk` is not 36.

## Rebuild the switch tool

`bin/usb_modeswitch` is a static arm64 binary. It writes one 31-byte mass-storage command to `12d1:1f01` or `12d1:14fe`. Configs live in `config/12d1.1f01` and `config/12d1.14fe`. Both target `12d1:14dc`.

```sh
zig cc -target aarch64-linux-musl -static -O2 -o bin/usb_modeswitch jni/usb_modeswitch.c
```

`jni/Android.mk` is the same source for `ndk-build` if you already use the NDK.

## AI disclosure

This module was written with Grok 4.7, a language model from SpaceXAI. Review the code before you install it on a phone.
