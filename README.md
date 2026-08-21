# gts7lwifi reboot-loop fix

KernelSU modules fixing kernel/hardware issues on a `gts7lwifi`/`gts7l`
("11 inch") tablet running third-party software ported from `gts9pwifi`
(Galaxy Tab S9+, SM-X810) donor firmware, on the third-party "Paradigm"
kernel. Two issues fixed so far, both stemming from the same underlying
theme: kernel driver behavior ported from the donor firmware not matching
this hardware.

1. [system_server reboot-loop](#1-system_server-reboot-loop) — `gpumem_abort_fix`
2. [0s deep sleep / always-awake](#2-0s-deep-sleep--always-awake) — `sdcard_suspend_fix`

Full investigation log for both, in the order things were actually
discovered, including dead ends: [`FINDINGS.md`](FINDINGS.md).

## 1. system_server reboot-loop

A KernelSU module that stops a system_server crash-loop (device appears to
reboot every ~2 minutes immediately post-boot, settling to a steady
~60-minute cadence thereafter).

### The problem

`system_server` aborts (`SIGABRT`) roughly every 2 minutes:

```
signal 6 (SIGABRT), Cmdline: system_server
#00 abort()                                                        libc.so
#01 android::bpf::BpfMapRO<uint64_t,uint64_t>::abortOnMismatch()    libmeminfo.so
#02 android::meminfo::ReadProcessGpuUsageKb()
#03 android_os_Debug_getGpuTotalUsageKb()  (JNI)
... invoked from statsd's periodic GPU-memory pull atom
```

The kernel's KGSL/Adreno driver never wires up the `gpu_mem_total`
tracepoint that `gpuservice`'s BPF program hooks into. Confirmed source-level
absent from the kernel tree (no `trace_gpu_mem_total`, `gpu_mem_total`, or
any `gpu_mem.h` hooks anywhere) — not a config toggle, a genuinely missing
feature. So `/sys/fs/bpf/map_gpuMem_gpu_mem_total_map` never gets created.
Every ~2 minutes `statsd` tries to read it anyway; `libmeminfo`'s
`BpfMapRO` sees an invalid fd and, instead of failing gracefully,
immediately calls `abort()` — killing `system_server` and forcing the whole
Android framework to restart, which looks and feels exactly like a reboot
(the kernel itself never actually restarts).

Full investigation writeup, including everything ruled out along the way
and independent corroboration from an existing (differently-targeted, not
fully effective) community hotfix module: [`FINDINGS.md`](FINDINGS.md).

### The fix

`scripts/patch_libmeminfo.py` changes exactly one 4-byte ARM64 instruction
in `/system/lib64/libmeminfo.so`: the first check inside
`BpfMapRO::abortOnMismatch()` (a `tbnz` testing for an invalid fd) is
redirected straight to the function's own success epilogue instead of
falling through to `abort()`. This neutralizes all 5 abort paths in that
function in one edit — `system_server` now treats a missing/invalid BPF
map the way it arguably always should have: as "no GPU memory stats
available," not as fatal.

```
16f88: tbnz w8, #0x1f, 0x17130   ; before: fd<0 -> abort()
16f88: b    0x17118              ; after:  fd<0 -> return normally
```

Packaged as `ksu-module/`, a KernelSU module that bind-mounts the patched
library over the real one at boot (`post-fs-data.sh` — standard KSU
module-overlay mounting did not actually take effect on this
kernel/KernelSU-Next combination, confirmed via `/proc/1/mounts`, so this
uses the same manual `mount --bind` workaround the pre-existing community
hotfix module used successfully for a different file).

### Install

```sh
# on-device, as root (KernelSU su)
ksud module install gpumem_abort_fix.zip
reboot
```

Or build the module zip yourself from a fresh pull:

```sh
adb pull /system/lib64/libmeminfo.so bin/libmeminfo.so.orig
python3 scripts/patch_libmeminfo.py bin/libmeminfo.so.orig ksu-module/system/lib64/libmeminfo.so
cd ksu-module && zip -r ../gpumem_abort_fix.zip module.prop post-fs-data.sh system/
```

**The patch script checks the input file's bytes at the target offset
before patching and refuses to run if they don't match** — it will not
silently produce a broken library against a different `libmeminfo.so`
build. If your build differs, you'll need to re-derive the offsets
yourself (see `FINDINGS.md` for the full method: pull the tombstone,
match the crash PC to `nm -D`/`objdump -d` output, find the equivalent
`abortOnMismatch` entry point).

### Verified

Post-install: a full 20-minute targeted system_server crash watch
completed with zero crashes (pre-patch, this crashed every ~2 minutes
without exception), plus a broad `adb logcat` sweep — native crashes,
Java crashes, ANRs, dropbox crash records, SELinux denials, RescueParty
escalation, not just the specific signature above — clean for the entire
post-boot period. Full verification log in `FINDINGS.md`.

### Caveats

- This is a workaround, not a real fix — it doesn't restore GPU memory
  telemetry, it stops the crash. The actual fix is upstream: the kernel
  needs the `gpu_mem_total` tracepoint wired into KGSL.
- The patch is specific to the exact `libmeminfo.so` build it was derived
  against (BuildID `51a394c7983db99c0a0bb512bdb48f2a`). A different
  firmware/kernel update will very likely ship a different build and
  require re-deriving the offset.
- `abortOnMismatch` at this address is called from exactly two places in
  the binary — `ReadProcessGpuUsageKb` (the one that crashes) and
  `ReadPerProcessGpuMem` (a per-process breakdown) — both GPU-memory
  reads against the same map shape. Confirmed via `objdump`, nothing else
  in the binary routes through this check, so the patch's blast radius is
  scoped to GPU-mem reads, not general-purpose BPF map validation. See
  `FINDINGS.md` for the search.

## 2. 0s deep sleep / always-awake

A KernelSU module fixing a device that never enters real suspend — third-
party battery tools (e.g. Franco Kernel Manager) show 0 seconds of deep
sleep and the device reads as continuously "awake" even with the screen
off for hours.

### The problem

The device has a physical microSD card slot. On every suspend attempt,
that card's bus gets stuck busy right at the moment of suspend, its
`mmc_bus_suspend` kernel PM callback fails, and the kernel's power
management core treats that failure as fatal — **aborting the entire
system suspend**, not just the card's own. `dmesg` shows the mechanism
directly:

```
mmc0: Card stuck in wrong state! card_busy_detect status: 0xf00
dpm_run_callback(): mmc_bus_suspend+0x0/0x98 returns -123
PM: Device mmc0:59b4 failed to suspend async: error -123
mmc0: card 59b4 removed
mmc0: new ultra high speed SDR50 SDHC card at address 59b4
```

Quantified across a 23-hour logged window: 1213 suspend attempts, 879
(72%) aborted by this exact cause, zero suspend gaps longer than 2
minutes anywhere in the whole window. Root cause is this kernel's SDHCI
driver (`8804000.sdhci`/`sdhci_msm`, ported from the gts9p donor firmware)
not handling this SD card's bus power-down cleanly on the real hardware —
confirmed by physically removing the card, which fixed it immediately and
completely (kernel `suspend_stats` went from 20 successes in 23 hours to
95 successes in the first 90 seconds with the card out).

This is a kernel PM-callback-level bug — not something a userspace
library patch (like the reboot-loop fix above) can reach.

### The fix

Since the physical card can't be patched and the kernel driver can't be
patched from a KernelSU module, `sdcard_suspend_fix` works around it at
the driver-binding level instead: it polls screen wakefulness
(`dumpsys power`, `mWakefulness`) every 2 seconds, and:

- A few seconds after the screen turns off (debounced, so a quick screen
  blip doesn't churn the driver), it **unbinds** the SDHCI platform
  driver (`echo 8804000.sdhci > /sys/bus/platform/drivers/sdhci_msm/unbind`).
  This cleanly tears the SD card's device node out of the kernel's device
  model entirely — there's nothing left for suspend to fail on, since the
  device it would have failed on no longer exists.
- Immediately on screen-on, it **rebinds** the same driver, which
  re-probes the controller and re-detects the card if it's still
  physically present.

Net effect: the SD card is usable while the screen is on, and real deep
sleep works once it's off. It's a genuine tradeoff (SD card access is
unavailable while suspended/screen-off) rather than a full fix, because
the actual fix requires a kernel driver/DTS patch for this SD
controller+card combination, which is out of scope for a userspace
module.

### Install

```sh
ksud module install sdcard_suspend_fix.zip
reboot
```

### Verified

Live-tested through multiple full off/on cycles before and after a real
reboot (not just a manually-launched script): confirmed via
`/sys/power/suspend_stats` that zero new suspend failures occur while the
driver is unbound (card physically present the whole time), and that
`success` climbs rapidly (45 new successes in a single ~20s window) once
unbound. Confirmed the service auto-starts under KSU's own process after
a real reboot (not just when launched manually for testing), and correctly
handles the case where the screen is already off when the service starts.
Full test log in `FINDINGS.md`.

### Caveats

- SD card is unavailable (unmounted, not visible to any app) whenever the
  screen is off. If something needs background SD card access while the
  screen is off (e.g. a sync job), this module will break that.
- The 8-second unbind debounce is a judgment call, not derived from any
  measurement — long enough to avoid driver churn on a quick screen
  glance, short enough to still capture most real idle periods. Adjust
  `UNBIND_DELAY` in `service.sh` if needed.
- Device/driver names (`8804000.sdhci`, `sdhci_msm`) are specific to this
  hardware. Confirm yours match (`readlink /sys/devices/platform/soc/
  <node>/driver`) before relying on this on a different device.
- Separately discovered (not caused by this module, doesn't affect it):
  this SD card fails its own filesystem check every time it's mounted
  (`fsck_msdos` reports `could not read boot block`) - a pre-existing
  read-reliability issue with this SDHCI controller/card combination,
  unrelated to lock state or fstab config. Open, unresolved, tracked in
  `FINDINGS.md`.

## Repo layout

- `FINDINGS.md` — full investigation log for both issues, in the order
  things were actually discovered, including dead ends.
- `scripts/patch_libmeminfo.py` — reproducible patch generator for fix 1.
- `bin/libmeminfo.so.orig` / `bin/libmeminfo.so` — the original and
  patched library for fix 1, pulled from this specific device build.
- `ksu-module/` — installable KernelSU module source for fix 1.
- `gpumem_abort_fix.zip` — built module for fix 1, ready to install.
- `ksu-module-sdcard-suspend/` — installable KernelSU module source for
  fix 2.
- `sdcard_suspend_fix.zip` — built module for fix 2, ready to install.
