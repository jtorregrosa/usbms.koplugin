#!/bin/sh
# usbms.koplugin framework helper (alternative method). main.lua copies it to /var/tmp and starts it detached, then quits KOReader.
#
# KOReader's koreader.sh SIGSTOPs volumd while KOReader runs, and on any exit code other than 85 it
# resumes volumd and restarts the Amazon framework. With the cable plugged into a computer, volumd
# then exports the userstore as usual (NiLuJe, koreader PR #3955, tested on a PW2). This helper
# waits for that USB session to start and end, then starts KOReader again.
#
# It must never touch /mnt/us while it waits: it runs from /var/tmp with / as its working directory,
# and holds no file under /mnt/us open, or volumd could not unmount the userstore.
#
# Usage: usbms_framework.sh READER_PID LAUNCH_FLAG AUTO_RETURN PLUG_TIMEOUT TOKEN

READER_PID=$1
LAUNCH_FLAG=${2:---framework_stop}
AUTO_RETURN=${3:-1}
PLUG_TIMEOUT=${4:-120}
TOKEN=$5

WORK=/var/tmp/usbms-koplugin
# /var/local is persistent (ext3), so the log survives the reboot that a stuck session needs.
LOG=/var/local/usbms-koplugin.log
PIDFILE="$WORK/helper.pid"
LOCK="$WORK/lock"
READY="$WORK/ready"
KOREADER_SH=/mnt/us/koreader/koreader.sh
CONNECTED=/sys/devices/platform/fsl-usb2-udc/gadget/connected
CLEAN_PATH=${PATH:-/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}

cd / || exit 1
trap '' HUP

# Drop every descriptor inherited from KOReader, so none of them pins a file on the userstore.
for fd in $(ls /proc/$$/fd 2>/dev/null); do
    [ "$fd" -gt 2 ] 2>/dev/null && eval "exec $fd>&-" 2>/dev/null
done

log() { echo "$(date '+%H:%M:%S') $*" >> "$LOG"; }

# volumd only unmounts the vfat on /mnt/base-us while exporting; the fuse proxy on /mnt/us stays
# mounted (traced on a PW2, FW 5.12.2.2), so that is the mount to watch.
userstore_mounted() { grep -q ' /mnt/base-us ' /proc/mounts; }

safe_to_launch() {
    userstore_mounted && [ "$(cat "$CONNECTED" 2>/dev/null)" = "0" ] &&
        [ "$(lipc-get-prop com.lab126.volumd userstoreIsAvailable 2>/dev/null)" = "1" ]
}

cancelled() {
    [ "$(cat "$LOCK/token" 2>/dev/null)" != "$TOKEN" ] || [ -f "$LOCK/cancel" ]
}

[ -n "$TOKEN" ] && [ "$(cat "$LOCK/token" 2>/dev/null)" = "$TOKEN" ] || exit 1
[ "$(cat "$LOCK/pid" 2>/dev/null)" = "$READER_PID" ] || exit 1
trap 'rm -rf "$LOCK"; rm -f "$PIDFILE"' EXIT
trap 'exit 1' INT TERM
cancelled && exit 1
echo $$ > "$LOCK/pid" || exit 1
echo $$ > "$PIDFILE" || exit 1
echo "$TOKEN" > "$READY" || exit 1

: > "$LOG"
log "start: reader=$READER_PID flag=$LAUNCH_FLAG auto_return=$AUTO_RETURN plug_timeout=${PLUG_TIMEOUT}s"
leaks=$(ls -l /proc/$$/fd 2>/dev/null | grep -c '/mnt/')
[ "$leaks" -gt 0 ] && log "warning: $leaks descriptors still point into /mnt"

launch_koreader() {
    if ! safe_to_launch; then
        log "storage or USB state is not safe, staying in the Amazon UI"
        return 1
    fi
    if [ ! -x "$KOREADER_SH" ]; then
        log "no $KOREADER_SH, staying in the Amazon UI"
        return 1
    fi
    log "starting KOReader ($LAUNCH_FLAG)"
    # Clean environment: the one inherited from the old KOReader carries its launcher state.
    setsid=$(command -v setsid)
    ( env -i PATH="$CLEAN_PATH" $setsid "$KOREADER_SH" "$LAUNCH_FLAG" < /dev/null > /dev/null 2>&1 & )

    # If KOReader does not come up and nothing else owns the screen, bring the framework back.
    n=0
    while [ "$n" -lt 90 ]; do
        pidof reader.lua > /dev/null 2>&1 && { log "KOReader is running"; return 0; }
        sleep 1
        n=$((n + 1))
    done
    if ! status lab126_gui 2>/dev/null | grep -q 'start/running'; then
        log "KOReader did not start, restarting the framework"
        start lab126_gui
    else
        log "KOReader did not start, the framework is up"
    fi
    return 1
}

# 1. Wait for KOReader to exit (main.lua quits right after starting us).
n=0
while [ -n "$READER_PID" ] && [ -d "/proc/$READER_PID" ] && ! grep -q '^State:.*Z' "/proc/$READER_PID/status" 2>/dev/null; do
    cancelled && exit 1
    if [ "$n" -ge 60 ]; then
        log "KOReader did not exit within 60 s, giving up"
        exit 1
    fi
    sleep 1
    n=$((n + 1))
done
log "KOReader exited; the launcher now resumes volumd and starts the framework"

# 2. Wait for volumd to unmount the userstore, which means the computer has the drive.
n=0
while userstore_mounted; do
    if [ "$n" -ge "$PLUG_TIMEOUT" ]; then
        log "no USB session after ${PLUG_TIMEOUT} s (no computer connected?)"
        [ "$AUTO_RETURN" = "1" ] && launch_koreader
        exit 0
    fi
    sleep 1
    n=$((n + 1))
done
log "USB drive mode started after ${n} s"
[ "$AUTO_RETURN" = "1" ] || exit 0

# 3. Wait for the session to end: eject or unplug makes volumd mount the userstore again. With the
#    cable still in, the host re-enumerates and volumd exports again a few seconds later, so
#    KOReader must not start until the cable is physically out. The UDC reports that.
while ! userstore_mounted; do
    sleep 2
done
log "userstore mounted again, waiting for the cable to be unplugged"
while [ "$(cat "$CONNECTED" 2>/dev/null)" != "0" ] || ! userstore_mounted; do
    sleep 2
done
log "cable unplugged"

# 4. Let volumd and the framework finish with the userstore before stopping the framework again.
n=0
until [ "$(lipc-get-prop com.lab126.volumd userstoreIsAvailable 2>/dev/null)" = "1" ]; do
    [ "$n" -ge 30 ] && { log "userstore availability timed out, staying in the Amazon UI"; exit 1; }
    sleep 1
    n=$((n + 1))
done
sleep 5
# Last look: still mounted and still no host.
if ! userstore_mounted || [ "$(cat "$CONNECTED" 2>/dev/null)" != "0" ]; then
    log "userstore or cable state changed again, staying in the Amazon UI"
    exit 0
fi
launch_koreader
