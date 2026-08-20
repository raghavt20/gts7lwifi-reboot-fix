# gts7lwifi reboot-loop fix

A KernelSU module that stops a system_server crash-loop (device appears to
reboot every ~2 minutes) on a `gts7lwifi`/`gts7l` ("11 inch") tablet running
third-party software ported from `gts9pwifi` (Galaxy Tab S9+, SM-X810)
donor firmware, on the third-party "Paradigm" kernel.

## The problem

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

## The fix

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

## Install

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

## Verified

Post-install: 10+ minutes clean on a targeted system_server crash watch
(pre-patch, this crashed every ~2 minutes without exception), plus a
broad `adb logcat` sweep — native crashes, Java crashes, ANRs, dropbox
crash records, SELinux denials, RescueParty escalation, not just the
specific signature above — clean for the entire post-boot period. Full
verification log, updated as monitoring continues, in `FINDINGS.md`.

## Repo layout

- `FINDINGS.md` — full investigation log, in the order things were
  actually discovered, including dead ends.
- `scripts/patch_libmeminfo.py` — reproducible patch generator.
- `bin/libmeminfo.so.orig` / `bin/libmeminfo.so` — the original and
  patched library pulled from this specific device build, for reference
  and diffing.
- `ksu-module/` — the installable KernelSU module source.
- `gpumem_abort_fix.zip` — the built module, ready to install.

## Caveats

- This is a workaround, not a real fix — it doesn't restore GPU memory
  telemetry, it stops the crash. The actual fix is upstream: the kernel
  needs the `gpu_mem_total` tracepoint wired into KGSL.
- The patch is specific to the exact `libmeminfo.so` build it was derived
  against (BuildID `51a394c7983db99c0a0bb512bdb48f2a`). A different
  firmware/kernel update will very likely ship a different build and
  require re-deriving the offset.
- `abortOnMismatch` may be shared (via identical-code-folding) across
  other `BpfMapRO<K,V>` instantiations in this binary beyond just the
  GPU-mem one — this patch makes all of them permissive rather than just
  the GPU-mem case. Not yet confirmed how broad the sharing is; see
  `FINDINGS.md`'s open items.
