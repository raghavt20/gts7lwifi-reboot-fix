#!/system/bin/sh
# gpumem_abort_fix: manual bind mount, because standard KSU module
# system/ overlay mounting does not actually land on this kernel
# (confirmed: ksud reports mount=true but /proc/1/mounts shows nothing).
# Same workaround the minsos_gpustats_hotfix module used successfully
# for services.jar on this device.
MODDIR=${0%/*}
SRC=$MODDIR/system/lib64/libmeminfo.so
TGT=/system/lib64/libmeminfo.so
LOG=$MODDIR/hotfix.log

echo "$(date) post-fs-data start" > "$LOG"

if [ ! -f "$SRC" ]; then
    echo "$(date) FAIL: $SRC missing" >> "$LOG"
    exit 0
fi

chcon u:object_r:system_file:s0 "$SRC" 2>>"$LOG"
chmod 0644 "$SRC" 2>>"$LOG"
echo "$(date) context now: $(ls -Z "$SRC" 2>/dev/null)" >> "$LOG"

if mount --bind "$SRC" "$TGT" 2>>"$LOG"; then
    echo "$(date) bind ok, target size $(stat -c %s "$TGT" 2>/dev/null), md5 $(md5sum "$TGT" 2>/dev/null)" >> "$LOG"
else
    echo "$(date) bind FAILED" >> "$LOG"
fi
