#!/system/bin/sh
# sdcard_suspend_fix: unbind the SDHCI driver a few seconds after the
# screen turns off (letting the device actually suspend, since this
# card's mmc_bus_suspend callback fails and aborts system suspend every
# time otherwise - see FINDINGS.md), and rebind immediately on screen-on
# so the card is usable while awake.
#
# service.sh runs as root already under KernelSU, no su prefix needed.

MODDIR=${0%/*}
LOG="$MODDIR/service.log"
SDHCI_NAME="8804000.sdhci"
SDHCI_DEV="/sys/devices/platform/soc/${SDHCI_NAME}"
SDHCI_DRV="/sys/bus/platform/drivers/sdhci_msm"
UNBIND_DELAY=8   # seconds to wait after screen-off before unbinding,
                 # so a quick screen blip doesn't churn the driver

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

is_bound() {
    [ -e "$SDHCI_DEV/driver" ]
}

do_unbind() {
    if is_bound; then
        echo "$SDHCI_NAME" > "$SDHCI_DRV/unbind" 2>>"$LOG"
        if is_bound; then
            log "unbind FAILED, still bound"
        else
            log "unbound $SDHCI_NAME (screen off) - device can now suspend"
        fi
    fi
}

do_bind() {
    if ! is_bound; then
        echo "$SDHCI_NAME" > "$SDHCI_DRV/bind" 2>>"$LOG"
        if is_bound; then
            log "bound $SDHCI_NAME (screen on) - SD card available"
        else
            log "bind FAILED, still unbound"
        fi
    fi
}

get_wakefulness() {
    dumpsys power 2>/dev/null | grep -m1 'mWakefulness=' | cut -d= -f2
}

log "service starting"

# wait for the system to be far enough into boot for dumpsys to answer
i=0
while [ -z "$(get_wakefulness)" ] && [ "$i" -lt 30 ]; do
    sleep 2
    i=$((i + 1))
done

state="unknown"
screen_off_since=0

while true; do
    w=$(get_wakefulness)
    now=$(date +%s)

    if [ "$w" = "Awake" ]; then
        if [ "$state" != "awake" ]; then
            do_bind
            state="awake"
        fi
        screen_off_since=0
    else
        # Asleep, Dozing, Dreaming, or dumpsys briefly unreadable - treat
        # as "not interactively awake" and debounce before unbinding
        if [ "$state" = "awake" ] || [ "$state" = "unknown" ]; then
            if [ "$screen_off_since" -eq 0 ]; then
                screen_off_since=$now
            elif [ $((now - screen_off_since)) -ge "$UNBIND_DELAY" ]; then
                do_unbind
                state="asleep"
            fi
        fi
    fi

    sleep 2
done
