#!/usr/bin/env python3
"""
Patches libmeminfo.so to stop system_server aborting when the
gpu_mem_total_map BPF map doesn't exist (missing gpu_mem_total kernel
tracepoint on this device's kernel).

Neutralizes android::bpf::BpfMapRO<uint64_t,uint64_t>::abortOnMismatch()
by replacing its first check (an fd<0 test that jumps straight to abort())
with an unconditional branch to the function's own success epilogue.
One 4-byte instruction change; everything else in the file is untouched.

See FINDINGS.md for the full derivation (tombstone address math, why this
specific instruction, why the naive "just skip the check" doesn't work).

Usage:
    python3 patch_libmeminfo.py <input.so> <output.so>

The input file must be the exact libmeminfo.so pulled from the target
device (`adb pull /system/lib64/libmeminfo.so`) — the function offset is
specific to that build. Verify with `nm -D` / `objdump -d` that
ReadProcessGpuUsageKb is still at the expected address before trusting
the patch on a different build; this script does not re-derive offsets.
"""
import struct
import sys

# Verified against this device's libmeminfo.so (BuildID
# 51a394c7983db99c0a0bb512bdb48f2a, matches the crash tombstone exactly).
# File offset == virtual address here because the containing ELF LOAD
# segment has off == vaddr (0xa000..0x21008, see `objdump -p`).
PATCH_OFFSET = 0x16F88
EXPECTED_ORIG = 0x37F80D48  # tbnz w8, #0x1f, 0x17130
BRANCH_TARGET_VADDR = 0x17118  # function epilogue: ldp/ldr/ldp/add sp/autiasp/ret


def build_patch():
    pc = PATCH_OFFSET
    delta = BRANCH_TARGET_VADDR - pc
    assert delta % 4 == 0, "branch target not instruction-aligned"
    imm26 = (delta // 4) & 0x3FFFFFF
    return 0x14000000 | imm26  # unconditional B <imm26>


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)

    src_path, dst_path = sys.argv[1], sys.argv[2]

    with open(src_path, "rb") as f:
        data = bytearray(f.read())

    orig_bytes = bytes(data[PATCH_OFFSET : PATCH_OFFSET + 4])
    orig_val = struct.unpack("<I", orig_bytes)[0]
    if orig_val != EXPECTED_ORIG:
        print(
            f"REFUSING TO PATCH: byte at 0x{PATCH_OFFSET:x} is "
            f"0x{orig_val:08x}, expected 0x{EXPECTED_ORIG:08x}.\n"
            f"This is not the same libmeminfo.so build this patch was "
            f"derived from — offsets will not line up. See FINDINGS.md.",
            file=sys.stderr,
        )
        sys.exit(2)

    new_val = build_patch()
    new_bytes = struct.pack("<I", new_val)
    data[PATCH_OFFSET : PATCH_OFFSET + 4] = new_bytes

    with open(dst_path, "wb") as f:
        f.write(data)

    print(f"patched 0x{PATCH_OFFSET:x}: 0x{orig_val:08x} -> 0x{new_val:08x}")
    print(f"wrote {dst_path} ({len(data)} bytes, size unchanged)")


if __name__ == "__main__":
    main()
