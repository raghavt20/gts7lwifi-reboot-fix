# gts7lwifi reboot-loop investigation

Goal: device reboots every ~2 min. Root-caused via `adb logcat`. Working toward a
KernelSU module fix. This file accumulates confirmed findings as we go — append,
don't rewrite history.

## Device — correction

The device is actually a **gts7lwifi/gts7l tablet** ("11 inch") running
**third-party software, not Samsung OEM software** — a ported/custom build
that uses `gts9pwifi` (Tab S9+, SM-X810) firmware as a **donor**. Everything
below that was written assuming this was literally a stock-ish Tab S9+ was
wrong about the physical hardware; `getprop`/the build fingerprint reports
the donor firmware's identity (`gts9pwifi`/`SM-X810`), not the real device.
This is *why* `minsos_gpustats_hotfix` (see below) — explicitly built "For
11 inch, gts7lwifi and gts7l only" — was already installed: it was correctly
targeted at this device, not a mismatch as originally assumed. It just
wasn't fully effective on this specific port/kernel/build combination (see
that section for details).

This doesn't change the root cause or the fix — both were derived from the
actual live kernel/binaries on the device, independent of which physical
hardware the donor firmware normally ships on. Kept the original
(donor-firmware-based) technical details below as-recorded since they're
still accurate for what's actually running.

## Device (as reported by the running donor firmware)
- Reports as: SM-X810 (Galaxy Tab S9+ Wi-Fi donor firmware), codename `gts9pwifi`
- Build fingerprint: `samsung/gts9pwifixx/gts9pwifi:16/BP4A.251205.006/X810XXS6EZF1:user/release-keys`
- Kernel: `4.19.325-Paradigm-g159176c6f4a2` — third-party "Paradigm" kernel,
  built to run gts9p donor firmware on gts7lwifi/gts7l hardware
  - Source: likely `pascua28/android_kernel_samsung_sm8550`, branch `sixteen`
  - Rooted via KernelSU (su domain = `u:r:ksu:s0`)
- adbd is NOT rootable directly (`adb root` → "cannot run as root in production
  builds"), but `adb shell su 0 <cmd>` works fine (KernelSU).

## Symptom
Device appears to fully reboot every ~2 minutes. Actually confirmed via `uptime`
that the **kernel never reboots** (uptime stayed continuous at ~4d22h) — it's
`system_server` crashing and the whole Android framework restarting
("userspace reboot"-looking behavior), which visually looks identical to a
real reboot.

## Root cause (confirmed)
`system_server` aborts with `SIGABRT` every ~2 minutes. Identical tombstone
signature every time (33 occurrences seen in one logcat buffer):

```
signal 6 (SIGABRT), Cmdline: system_server
#00 abort()                                            libc.so
#01 android::bpf::BpfMapRO<uint64_t,uint64_t>::abortOnMismatch()   libmeminfo.so
#02 android::meminfo::ReadProcessGpuUsageKb()
#03 android_os_Debug_getGpuTotalUsageKb()  (JNI)
... invoked from statsd's PullAtomCallback (GPU memory usage stat)
```

Trigger cadence matches `statsd`'s periodic GPU-memory pull atom.

**Correction (see "Crash cadence" section below): the true steady-state
period is ~60 minutes, not ~2 minutes.** The ~2 min figure originally
recorded here was measured from a narrow window right after a reboot and
mischaracterizes the actual pull interval — see below for the full
timestamp analysis.

### Why: the `gpu_mem_total_map` BPF map doesn't exist on this device
Verified with full root (`su 0 ls -laZ /sys/fs/bpf/` and all subdirs:
`loader`, `memevents`, `net_private`, `net_shared`, `netd_readonly`,
`netd_shared`, `tethering`, `uprobestats`, `vendor`):
- Dozens of other pinned maps/progs exist (netd, tethering, Samsung
  `semSmartHS`/`semUidBPF`, uprobestats, clatd, dscpPolicy, etc.)
- `map_gpuMem_gpu_mem_total_map` and `prog_gpuMem_tracepoint_gpu_mem_gpu_mem_total`
  are **absent everywhere**, including an empty `vendor/` dir.
- SELinux is Enforcing, but this isn't a visibility issue — root+ksu domain
  sees everything else fine.

Conclusion: `gpuservice`'s GPU-memory BPF program never loaded/pinned at
boot. That program hooks a kernel `gpu_mem_total` tracepoint (Adreno/KGSL
vendor-hook territory). If the kernel doesn't expose that tracepoint, the
bpfloader silently fails to create the map — it's just missing. Then every
statsd pull cycle, `system_server` tries to open it via `libmeminfo`'s
`BpfMapRO`, fails, and instead of failing gracefully hits
`abortOnMismatch()` → crash.

This is a **kernel-side gap** (missing GPU-mem tracepoint/vendor hook),
most likely specific to the Paradigm kernel build, not present in stock
Samsung kernel (which Samsung's own telemetry presumably depends on).

### Dead ends / ruled out
- NOT `InactivityRestartService` (Samsung auto-restart-on-lock feature) —
  its alarm is scheduled ~3 days out, far too infrequent to explain this.
  (`inactivity_restart=1` global setting is on, but irrelevant here.)
- NOT a real hardware/kernel reboot — uptime is continuous.
- NOT a PackageWatchdog/RescueParty active mitigation — the RescueParty log
  lines seen are just normal namespace-observer registration at boot, no
  escalation/mitigation messages found.
- NOT the AOSP bug fixed in `bebda53` "Fix the group of gpu_mem_total_map"
  (GID_MEDIA_RW → GID_GRAPHICS, merged into `system/bpf` main 2025-06-02,
  Bug 410982483) — that assumes the map exists with wrong group; on this
  device the map doesn't exist at all, so that's a different failure mode.
  Worth keeping in mind though: this whole map/loader path has been actively
  buggy in AOSP around the Android 16 timeframe.
- Checked `pascua28/android_kernel_samsung_sm8550` (branch `sixteen`) full
  commit history + code search: zero commits/files touching `gpu_mem`,
  `gpuMem`, or `GID_GRAPHICS`. Confirms this isn't something already
  patched/regressed in a recent kernel commit — it's just never been wired up.

## Confirmed: kernel source genuinely lacks GPU-mem tracepoint (not just disabled)

Root-shell `/proc/config.gz` dump (`zcat` via `su 0`, 6871 lines):
- `CONFIG_QCOM_KGSL=y`, `CONFIG_QCOM_KGSL_IOMMU=y`, `CONFIG_DEVFREQ_GOV_QCOM_ADRENO_TZ=y`
  — Adreno/KGSL GPU driver is **built directly into the kernel image**
  (confirmed: `lsmod` shows no kgsl/adreno/gpu module — nothing to load,
  it's compiled in). So this rules out the "prebuilt vendor .ko GKI ABI
  mismatch" theory — it's not a separate vendor blob, it's source pascua28
  actually compiles.
- No `TRACE_GPU_MEM`/`GPU_MEM` tracepoint config symbol exists anywhere in
  the config at all (only unrelated `*_GPUCC_*` clock-controller symbols
  matched "gpu").
- `CONFIG_ANDROID_VENDOR_HOOKS=y` is enabled (so the kernel supports vendor
  hooks in general — this specific one just isn't wired up).
- `dmesg` via root returned nothing relevant (buffer likely rotated after
  5 days uptime — inconclusive, not a blocker).

**Source-level confirmation** (GitHub code search scoped to
`pascua28/android_kernel_samsung_sm8550`):
- `trace_gpu_mem_total` — 0 matches
- `gpu_mem_total` — 0 matches
- `trace_android_vh_gpu_mem` — 0 matches
- any `gpu_mem.h` hooks header — 0 matches

**Conclusion: this is not a config/loading failure, it's a straight-up
missing feature in the kernel source.** The KGSL driver never calls into
any `gpu_mem_total` tracepoint, so `gpuservice`'s BPF program has nothing
to attach to and the map is never created. A real fix needs someone to add
the tracepoint call sites (Android Common Kernel provides these as a
patch series — Samsung's stock kernel presumably carries it; this rebased
tree apparently doesn't).

## Fix strategy for a future KernelSU module (workaround, not a real kernel fix)

A KSU module runs userspace-side (or ships a loadable .ko) — it **cannot**
retroactively add a missing kernel tracepoint to a monolithic (non-modular)
KGSL driver that's compiled directly into the kernel image. So the module
has to work around the crash rather than restore real GPU-mem telemetry.
Two candidate approaches, not yet prototyped:

1. **Binary-patch `/system/lib64/libmeminfo.so`** (systemless overlay via
   KSU module, standard technique) to make `BpfMapRO::abortOnMismatch()` a
   no-op instead of calling `abort()` — restores the "fail gracefully"
   behavior the class should arguably have had for a simply-absent map.
   Most direct fix, but requires pulling the exact `libmeminfo.so` off
   this device, disassembling it, and finding/patching the right
   call site (NOP the `bl abort`). Needs the device's actual `.so`, not
   guessable from AOSP source alone since Samsung's build may differ.
   → Most promising, but requires binary RE work not yet started.

2. **Pre-create/pin a stub `map_gpuMem_gpu_mem_total_map`** at boot
   (BPF_MAP_TYPE_HASH, key/value both u64, max_entries 1024, owned
   root:graphics, matching AOSP's `frameworks/native/services/gpuservice/
   bpfprogs/gpuMem.c` definition) before gpuservice's own loader runs, so
   `libmeminfo`'s read finds a validly-shaped (if empty) map instead of
   nothing. Risk: gpuservice's own bpfloader may still try to create/pin
   it itself at boot and conflict with our stub — untested, need to check
   ordering (bpfloader is an early init service, likely runs before we
   could inject a service script in a KSU module — post-fs-data.sh might
   be too late).
   → Simpler in principle, ordering/conflict risk unconfirmed.

Not yet decided which to pursue. Approach 1 is more surgical (fixes the
actual crash unconditionally); approach 2 is closer to "restoring real
functionality" but riskier w.r.t. init ordering.

## `libmeminfo.so` pulled and disassembled (approach 1 progress)

Pulled via plain `adb pull /system/lib64/libmeminfo.so` — no root needed,
world-readable (`-rw-r--r-- root root`). Saved to
`~/gts9p-reboot-fix/bin/libmeminfo.so`
(sha256 `da071344d475717a38baa4aee196cc22d2a19e31ced1613761b8e6a9e670c31d`).

**BuildID confirmed exact match to the crash tombstone**:
`51a394c7983db99c0a0bb512bdb48f2a` — this is unambiguously the same binary
that's crashing, not a different version.

ARM64 (aarch64), stripped of local symbols but dynsym still has
`_ZN7android7meminfo21ReadProcessGpuUsageKbEjjPm` at `0x13b20`. Confirmed
address math lines up with the tombstone exactly:
- Tombstone frame #02: `ReadProcessGpuUsageKb+136` → `0x13b20 + 0x88 = 0x13ba8` ✓
- Tombstone frame #01: `abortOnMismatch(bool) const+452` → function base
  `0x17130 - 452(0x1C4) = 0x16f6c`, which is exactly the target of the
  `bl` at `0x13ba8`. Confirms the call chain precisely.

**Found the exact abort trigger.** The function at `0x16f6c` (objdump
mislabels it as `ParseSizeToBytes+0x2f6c` — that's just nearest-dynsym
guessing on a stripped local/ICF-folded function, not its real identity)
opens with:

```
16f84: ldr  w8, [x0]              ; w8 = *this->mFd  (first 4 bytes of the object)
16f88: tbnz w8, #0x1f, 0x17130    ; if sign bit set (fd < 0, i.e. invalid/missing map) → abort
...
17130: bl   abort@plt             ; <-- THE crash instruction, exact match to tombstone PC 0x17130
```

This is `BpfMapRO`'s validation method checking `mFd`. Since
`gpu_mem_total_map` doesn't exist, the underlying `bpf_obj_get()` pin
lookup that constructs this `BpfMapRO` fails and leaves `mFd = -1`. The
*very first thing* this function does is check for that and abort
immediately — no graceful "map missing" handling exists at all.

Note: the function has **5 separate `abort@plt` call sites** total
(`0x17130, 0x17134, 0x17144, 0x17154, 0x17164`) — one for the initial
invalid-fd check, and others for `bpf()` syscall failure / size-mismatch
checks further down. Just skipping the first check isn't enough: if `mFd`
is negative and we fall through, the subsequent `bpf(BPF_OBJ_GET_INFO_BY_FD,
fd=-1, ...)` syscall at `0x17000` will itself fail and route into another
abort path (`0x17018` → `0x17144`). So the safe patch is **redirecting the
very first check straight to the function's success epilogue**, not just
deleting the check.

### Proposed patch
Replace the instruction at file offset `0x16f88`
(`tbnz w8, #0x1f, 0x17130`, encoding `0x37f80d48` per objdump / big-endian
words — actual little-endian file bytes need care) with an unconditional
branch to the epilogue at `0x17118` (`ldp x20,x19,[sp,#0x120]; ...; ret`):

- Offset = `0x17118 - 0x16f88 = 0x1A0` = 416 bytes = 104 instructions
- `B` encoding = `0x14000000 | (416/4)` = `0x14000000 | 0x68` = `0x14000068`
- i.e. this one 4-byte instruction change makes the whole validation
  function unconditionally "succeed" (treat every map as valid), which
  fully neutralizes all 5 abort paths in one patch, not just the fd check.

**Caveat / risk**: neutering this check makes `abortOnMismatch` a no-op for
*all* `BpfMapRO` instantiations that share this folded function (ICF may
have merged multiple template instantiations into this one body — need to
confirm whether other BPF maps' size-checks route through this exact same
function or a separate copy, since over-broadly disabling validation for
*other* maps could mask real corruption elsewhere). Also noticed
`paciasp`/`autiasp` (ARMv8.3 pointer authentication) in this function and
neighbors — patching must not break PAC-protected return address handling;
since we're only touching a mid-function branch (not prologue/epilogue),
should be safe, but must verify after patching.

**Resolved (blast-radius check).** Searched the full binary
(`objdump -d libmeminfo.so.orig | grep 'bl.*16f6c'`) for every caller of
this function. There are exactly two:
- `0x13ba8` — inside `ReadProcessGpuUsageKb` (the one that crashes,
  statsd's periodic pull target).
- `0x13048` — inside `ReadPerProcessGpuMem` (a per-process GPU-memory
  breakdown; from the name/signature this looks `dumpsys`/diagnostic
  triggered rather than periodic, not independently confirmed).

Nothing else in the binary calls into this check. Both callers read the
same map shape (`BpfMapRO<uint64_t,uint64_t>` against `gpu_mem_total_map`)
— the patch's blast radius is scoped precisely to GPU-memory BPF reads,
not some general-purpose shared validator. It does not touch validation
for any unrelated BPF map (netd, tethering, uid stats, etc. all have their
own separately-instantiated template code elsewhere in other libraries).

## Discovered: an existing community hotfix module was already active

(Correction: originally wrote this up as "mismatched foreign module" —
that was wrong, see the Device correction note at the top. It's actually
built for this exact device, just not fully effective here.)

While checking for `ksud` (KernelSU CLI) to install our module, found
`/data/adb/modules/minsos_gpustats_hotfix` already installed and **live**:

- `module.prop`: *"MinsOS GPU stats crash hotfix (11 inch, gts7lwifi and
  gts7l)"* — *"Stops system_server aborting every thirty minutes on MinsOS
  v1.0.0. Skips the GPU memory figures in the statsd process memory
  snapshot, which read a kernel BPF map this 4.19 kernel never creates.
  For 11 inch, gts7lwifi and gts7l only. Remove this before updating the
  ROM."*
- This independently corroborates our root-cause diagnosis almost
  word-for-word (different device family, same underlying kernel gap: a
  4.19 kernel that never creates the GPU-mem BPF map). Good outside
  confirmation we identified the right cause.
- It works via `post-fs-data.sh` doing `mount --bind` of its own bundled
  `services.jar` (a MinsOS-ROM build) over the real
  `/system/framework/services.jar` — **confirmed actively mounted**
  (`/proc/1/mounts` showed it live; live file's md5sum
  `bc3e12aee79c3ceb24c630de3b607f9b` exactly matched the module's bundled
  replacement, both 26,947,922 bytes).
- Despite being correctly targeted at this device family, it was **not**
  stopping the crash here (still crashing every ~2 min, not the ~30 min its
  description mentions for MinsOS v1.0.0) — likely because this build's
  actual `services.jar` (from the gts9p donor firmware, a different base
  than MinsOS v1.0.0) doesn't have the method/bytecode layout the module's
  patch targets. A bytecode-offset patch built against one `services.jar`
  doesn't reliably transfer to a differently-built one.
- Removed via `ksud module uninstall minsos_gpustats_hotfix` (proper CLI
  removal, not a raw `rm -rf` — can't literally delete an actively
  bind-mounted file, so KSU marks `remove: true` and it's fully removed at
  next boot, restoring the real stock `services.jar`).
- User was asked how to handle this and chose: remove it, then install our
  fix on a clean baseline.

**Update, from the port's developer**: MinsOS 1.1.0 carries this same fix
inside the ROM itself, no module needed — `minsos_gpustats_hotfix` was
built for 1.0.0. This device is on 1.0.0 (confirmed). So there are two
independent ways to fix this: this repo's module (works today, needs
maintaining across ROM updates), or updating to MinsOS 1.1.0 (native fix,
no module to maintain, but is a full ROM update). If updating to 1.1.0,
this module should be removed first — same reasoning as removing
`minsos_gpustats_hotfix` was: an old module bind-mounting a file the newer
base doesn't need is more likely to cause problems than help.

## Module installed (staged for next boot)

Built as a proper KernelSU module via `ksud`, not manual file placement:
- Zipped `ksu-module/` (`module.prop` + `system/lib64/libmeminfo.so`, the
  patched binary from the previous section) → `gpumem_abort_fix.zip`
- `adb push` to `/data/local/tmp/`, then
  `su 0 ksud module install /data/local/tmp/gpumem_abort_fix.zip`
- Installed cleanly to `/data/adb/modules_update/gpumem_abort_fix`
  (staged; `ksud module list` shows `id: gpumem_abort_fix, enabled: true,
  update: true, mount: false` — moves into place and mounts on next boot,
  standard KSU staged-install behavior).
- Both this install and the `minsos_gpustats_hotfix` removal take effect
  together **on the next real kernel boot** — NOT on the spontaneous
  system_server crash-restarts we've been observing, since those don't
  redo KSU's early-init module mounting.

**Not yet done: the actual reboot to test.** Holding here — rebooting a
device that's already had boot-adjacent issues is the user's call, and
they should know KSU's safe-mode escape hatch (hold volume-down through
boot to skip mounting all modules) before doing it, in case anything goes
wrong.

## First reboot attempt: standard module mount didn't actually apply

After first reboot: `ksud module list` reported `gpumem_abort_fix` as
`mount: true`, `minsos_gpustats_hotfix` correctly gone, real
`services.jar` restored (md5 changed from `bc3e12ae...` back to
`3de0f6f3...`). **But** `/system/lib64/libmeminfo.so`'s live md5
(`242a9922bc9e4fe60c51704cc24724d6`) matched the *original unpatched*
file, not our patch (`d9c7a07297ef25c43638a931a9d33641`). `/proc/1/mounts`
had zero entries for `libmeminfo`/`lib64`/overlay-on-`/system` — KSU's
standard module `system/` overlay mount never actually landed, despite
`ksud` reporting `mount: true` (that field is apparently just config
intent, not a live guarantee).

**This is exactly the same failure mode `minsos_gpustats_hotfix`'s own
script commented on** ("KernelSU lists the module as enabled with
mount=true, and nothing lands... the mount backend this ROM expects is not
installed") — except we now have direct evidence it's not specific to
MinsOS's ROM, it's this Paradigm-kernel/KernelSU-Next combo in general.
Whatever magic-mount backend KSU-Next needs (overlayfs support or similar)
isn't functioning here for standard module installs.

**Fix**: copied the exact same workaround the MinsOS module used
successfully (confirmed via its own `hotfix.log` + live mount check) — a
`post-fs-data.sh` that does a manual `mount --bind` instead of relying on
KSU's automatic overlay:

```sh
MODDIR=${0%/*}
SRC=$MODDIR/system/lib64/libmeminfo.so
TGT=/system/lib64/libmeminfo.so
chcon u:object_r:system_file:s0 "$SRC"
chmod 0644 "$SRC"
mount --bind "$SRC" "$TGT"
```

Repackaged, reinstalled via `ksud module install` (overwrites in place),
rebooted again.

## Second reboot: confirmed working

- `hotfix.log`: `bind ok, target size 149376, md5
  d9c7a07297ef25c43638a931a9d33641` — matches our patched file exactly.
- `/proc/1/mounts` now shows a live bind mount for
  `/system/lib64/libmeminfo.so`.
- Live `md5sum /system/lib64/libmeminfo.so` = `d9c7a07297ef25c43638a931a9d33641`
  — **the patched binary is what's actually running.**
- Started a 20-minute `logcat` watch (buffer cleared first) for
  `Fatal signal`, `AndroidRuntime`, `abortOnMismatch`, `beginning of
  crash`, zygote/system_server death, ANRs. Previously the device crashed
  every ~2 minutes without fail, so a clean stretch is a strong signal.

## Broad crash sweep (not just the specific signature)

Separately from the targeted watch above, did a full sweep of everything
logged since boot, to catch any *other* regression the patch or the
module-removal/mount changes might have introduced:
- `logcat -b crash`: empty, no native crashes for any process.
- No `FATAL EXCEPTION` (Java crashes) anywhere in the buffer.
- No ANRs (`ANR in`, `Input dispatching timed out`).
- `dumpsys dropbox --print`: no crash tags recorded.
- Zero SELinux denials (`avc: ... denied`) — the module's `chcon`/bind
  mount didn't break any permission context.
- No RescueParty/PackageWatchdog mitigation triggered.
- The one thing that looked suspicious at a glance — 27 `statsd ...
  Gauge Stats puller failed` lines — all share the exact same timestamp
  (14:22:25.512, right at boot), a normal one-time "some pullers aren't
  ready yet this early in boot" batch, not a recurring pattern tied to
  the GPU-mem pull cadence.
- Zero recurrences of `abortOnMismatch`/`ReadProcessGpuUsageKb` anywhere.

## Verification status: confirmed

Targeted system_server watch completed its full 20-minute run with zero
crashes (four 5-minute heartbeats all clean, watch self-terminated at the
1200s mark rather than being cut short). Broad sweep above stayed clean
for the entire post-boot period. Given the pre-patch cadence was a crash
every ~2 minutes without exception, **20 crash-free minutes is a
conclusive result — the fix is verified working.**

## Operational notes
- After a **real** reboot (not the framework-only crash-restarts), `adb`
  sometimes doesn't reconnect over USB on its own — toggling USB debugging
  off/on in Developer Options on the device fixed it once. Worth knowing
  for next time if `adb wait-for-device` hangs.
- `ksud module install` on an existing module id overwrites it in place
  (staged to `/data/adb/modules_update/<id>`, applied at next boot) — no
  need to uninstall/reinstall separately when iterating on our own module.

## Next steps
- [ ] Confirm 20-minute logcat watch stayed clean (append result here).
- [ ] If clean: consider this fix validated. Update module description /
      this doc to reflect "confirmed working" status.
- [ ] Confirm whether `0x16f6c` is shared by other BpfMap size-checks
      (search other call sites that `bl 0x16f6c`) — if so, the patch is
      "always trust the map is well-formed" globally, which is probably
      fine (Android's own intent was clearly "abort is too aggressive")
      but worth confirming scope before committing.
  - [ ] Confirm approach 2 init-ordering question is now moot / deprioritized
        given approach 1 has a concrete, minimal patch ready to test — but
        keep as fallback if the binary patch proves unstable.
- [ ] Actually apply the patch to a copy of the `.so` (hex-edit at the
      correct little-endian file offset — need to locate `0x16f88` as a
      *file offset*, not just a virtual address; requires checking the ELF
      program headers since `.text` load bias may differ from file offset).
- [ ] Push patched `.so` to device via a KSU module overlay
      (`system/lib64/libmeminfo.so` under the module's mount) and test
      whether the crash-loop stops without other regressions.
- [ ] Package as a KernelSU module (`module.prop` + the patched `.so`
      under `system/lib64/`) once validated on-device.

## Log artifacts
- Full logcat dump analyzed: session scratchpad
  `/private/tmp/claude-501/-Users-raghavt20/.../scratchpad/logcat_full.txt`
  (33 matching abort signatures via `grep -c abortOnMismatch`)

## Crash cadence: corrected (steady ~60 min in continuous operation, not ~2 min)

The original root-cause section above said "~2 min" cadence. That was
measured only from a narrow post-reboot window and is misleading as a
description of the actual periodic pull interval. Redid this properly by
pulling every `abortOnMismatch` timestamp across the full available
logcat history (spans 08-15 through 08-20, `grep abortOnMismatch` on the
full captured buffer, 32 unique timestamps) and computing the interval
between each consecutive pair:

```
08-17 19:24:36 -> 20:24:52  :  3615.7s  (60.3 min)
08-17 20:24:52 -> 21:25:30  :  3638.5s  (60.6 min)
08-17 21:25:30 -> 22:26:09  :  3638.4s  (60.6 min)
08-17 22:26:09 -> 23:26:25  :  3616.2s  (60.3 min)
08-17 23:26:25 -> 00:26:41  :  3616.5s  (60.3 min)
... (consistently 3616-3639s, i.e. 60.3-60.6 min, for every consecutive
    pair recorded while the device stayed up without a reboot in between)
```

**When the device is running continuously without a reboot, the crash
recurs on a remarkably steady ~60-minute period** (3616-3639s across
every measured interval, <1% jitter). That's the true `statsd` pull
interval for this atom on this build.

The ~2-minute figure comes from a *different* phenomenon: immediately
after any boot (real or the crash-induced framework restart), the first
one or two pulls happen in quick succession before settling into the
steady hourly rhythm:

```
08-17 18:19:48 -> 18:20:20  :    32.8s
08-20 13:26:46 -> 13:27:05  :    18.9s
08-20 13:27:05 -> 13:28:44  :    99.0s
08-20 13:28:44 -> 13:29:12  :    28.2s
```

If a device is manually rebooted repeatedly (e.g. a user reacting to what
looks like a crash by power-cycling again), it stays trapped in this
post-boot burst window indefinitely and never surfaces the true hourly
period — which is almost certainly why this originally read as "reboots
every few minutes" rather than "crashes every hour." Both the ~2 min and
~30-60 min descriptions are real and correct, they're just describing two
different regimes of the same bug: the immediate post-boot retry burst vs.
the steady-state periodic pull once a boot survives past the first minute
or two.

---

# Other issues observed (unrelated to the reboot loop above)

Separate device quirks noticed while working on this port. Not related to
the `abortOnMismatch`/GPU-mem crash — kept here since they're the same
underlying theme (donor-firmware/actual-hardware mismatches surfacing in
different subsystems) and the same device/repo.

## WiFi failed to come up after a reboot (one occurrence, self-resolved)

After a reboot (unrelated one, done to fix a SystemUI lockscreen theming
glitch), WiFi stayed disabled despite `wifi_on=1`. `dumpsys wifi` showed:

- `Current wifi mode: DisabledState`, `NumActiveModeManagers: 0`.
- The `WifiController` state-machine log showed `CMD_RECOVERY_DISABLE_WIFI`
  firing repeatedly (record counter in the tens of thousands) — Android's
  own WiFi self-recovery mechanism retrying and giving up, over and over,
  rather than a one-time failure.
- Root failure, in `SemHalDeviceManager` (Samsung's WiFi HAL layer, part
  of the gts9p donor firmware):
  ```
  SemHalDeviceManager: getVendorConnFileInfo: called but mSehWifi is null
  SemHalDeviceManager: createIface: createIfaceType=0, ...
  SemHalDeviceManager: Combination is NOT matched
  SemSupplicantStaIfaceHalHidlImpl: ISehSupplicantStaIface.setExtendedCommand
    failed: {.code = FAILURE_UNKNOWN, .debugMessage = -1}
  ```
  `Combination is NOT matched` means the HAL queried the kernel/chip for
  supported interface combinations (STA/AP/P2P coexistence) and didn't get
  back something it recognized as valid, so it refused to create the WiFi
  client interface at all — which is what fed the recovery-disable loop.

**Resolution: a second manual reboot fixed it completely** — WiFi came up
and connected normally on the next boot, no further changes made. Since a
genuine HAL/kernel capability mismatch would be expected to fail
identically on every boot, this looks like a **boot-time race/timing
glitch** in WiFi HAL init (e.g. something the HAL depends on not being
ready yet when it queried chip capabilities), not a hard incompatibility.
Not investigated further since it self-resolved. Worth checking this
section first if WiFi fails to come up again after a reboot — if it
recurs repeatedly (not just once), that would point back toward a real
capability mismatch worth digging into (similar to the GPU-mem case
above), possibly requiring a HAL-side patch analogous to the
`libmeminfo.so` fix.

## S Pen BLE remote pairing not established

`/efs/spen/blespen_addr` (the EFS-stored bonded S Pen BLE MAC address) is
0 bytes — empty. Basic pen writing/hover (EMR digitizer, no BLE involved)
works fine (`epen_count` shows hundreds of historical uses). What doesn't
work is the BLE-based "S Pen remote"/Air Command features (battery %, air
actions, remote shutter) — every pen insertion triggers a connect attempt
with `last paired address is null`, cycles
`CONNECTING -> DISCONNECTED/CANCELLED` every ~10-40s, and never succeeds.
Classic Bluetooth was also off at the time (`bluetooth_on=0`, 0 bonded
devices of any kind).

Likely cause: Samsung's S Pen BLE pairing is normally provisioned at the
factory (bundled pen <-> device serial pairing baked into EFS) — on this
donor-firmware port, that factory pairing record for this specific
physical pen plausibly never existed. Not yet fixed; suggested next step
is turning on full Bluetooth and trying a manual re-pair via Settings ->
Advanced features -> S Pen, if that flow exists in this build. Not
something a binary patch is applicable to (it's a pairing-state/data
issue, not a crash).
