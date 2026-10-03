#!/bin/sh
# Install the AP-safe CSI driver after the stock driver has completed boot.
# This script is idempotent so a supervisor can use it as a periodic health check.
# Once the candidate is loaded, the health path deliberately avoids all wl and
# nexutil calls: concurrent control ioctls can starve DHD while CSI table export
# is active. Reachability is checked by the RPi watchdog instead.
set -u

PATH=/sbin:/usr/sbin:/bin:/usr/bin
export PATH

CONFIG_FILE=${AP_CSI_CONFIG_FILE:-/jffs/csi/ap-csi.env}
if [ -r "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi

MODULE_PATH=${AP_CSI_MODULE_PATH:-/lib/modules/4.1.27/extra/dhd.ko}
CANDIDATE=${AP_CSI_CANDIDATE:-/jffs/csi/dhd-ap-concurrent.ko}
STOCK_BACKUP=${AP_CSI_STOCK_BACKUP:-/jffs/csi/dhd-stock-original-ac4f5be9.ko}
CONFIGURE=${AP_CSI_CONFIGURE:-/jffs/csi/configcsi-ap.sh}
NEXUTIL=${AP_CSI_NEXUTIL:-/jffs/csi/nexutil}
WL=${AP_CSI_WL:-/usr/sbin/wl}
IFCONFIG=${AP_CSI_IFCONFIG:-/sbin/ifconfig}
BRCTL=${AP_CSI_BRCTL:-brctl}
SERVICE=${AP_CSI_SERVICE:-/sbin/service}
RMMOD=${AP_CSI_RMMOD:-/sbin/rmmod}
INSMOD=${AP_CSI_INSMOD:-/sbin/insmod}
MOUNT=${AP_CSI_MOUNT:-/bin/mount}
UMOUNT=${AP_CSI_UMOUNT:-/bin/umount}
REBOOT=${AP_CSI_REBOOT:-/sbin/reboot}
MD5SUM=${AP_CSI_MD5SUM:-/usr/bin/md5sum}
NVRAM=${AP_CSI_NVRAM:-nvram}
SLEEP=${AP_CSI_SLEEP:-/bin/sleep}
KILLALL=${AP_CSI_KILLALL:-/usr/bin/killall}

EXPECTED_CANDIDATE=${AP_CSI_EXPECTED_CANDIDATE_MD5:-1e37e15766204e56924c277c3382a954}
EXPECTED_STOCK=${AP_CSI_EXPECTED_STOCK_MD5:-ac4f5be9e63816e1eea59490853c1b6b}
RADIO_INTERFACE=${AP_CSI_INTERFACE:-eth6}
BRIDGE=${AP_CSI_BRIDGE:-br0}
BRIDGE_INTERFACES=${AP_CSI_BRIDGE_INTERFACES:-"eth6 eth5"}
SSID=${AP_CSI_SSID:-WIRES-AP}
NVRAM_PREFIX=${AP_CSI_NVRAM_PREFIX:-wl1}
DISABLED_INTERFACES=${AP_CSI_DISABLED_INTERFACES:-eth5}
DISABLED_NVRAM_PREFIXES=${AP_CSI_DISABLED_NVRAM_PREFIXES:-wl0}
CHANNEL=${AP_CSI_CHANNEL:-36}
BANDWIDTH=${AP_CSI_BANDWIDTH_MHZ:-80}
TX_STREAMS=${AP_CSI_TX_STREAMS:-4}
# Leave the firmware filter empty when more than one phone is allowed. The
# paired RPi applies the exact source-MAC allowlist before publishing to MQTT.
TARGET_MAC=${AP_CSI_TARGET_MAC:-}
MIN_INTERVAL_MS=${AP_CSI_MIN_INTERVAL_MS:-${AP_CSI_PACKET_DELAY:-1}}
RX_CORES=${AP_CSI_RX_CORES:-4}
QUIESCE_PROCESSES=${AP_CSI_QUIESCE_PROCESSES:-"dhd_monitor roamast wlc_nt networkmap wps_monitor wpsaide wlceventd watchdog bwdpi_check cfg_server mastiff"}
QUIESCE_INTERVAL=${AP_CSI_QUIESCE_INTERVAL_SECONDS:-2}
QUIESCE_PID_FILE=${AP_CSI_QUIESCE_PID_FILE:-/tmp/ap-csi-quiesce.pid}
EXPECTED_CHANSPEC=$CHANNEL/$BANDWIDTH
LOG=${AP_CSI_LOG:-/tmp/ap-csi-autostart.log}
LOCK=${AP_CSI_LOCK:-/tmp/ap-csi-autostart.lock}
CONFIG_SIGNATURE_FILE=${AP_CSI_CONFIG_SIGNATURE_FILE:-/tmp/ap-csi-config.signature}
CONFIG_SIGNATURE=$RADIO_INTERFACE\|$SSID\|$NVRAM_PREFIX\|$DISABLED_INTERFACES\|$DISABLED_NVRAM_PREFIXES\|$EXPECTED_CHANSPEC\|$TX_STREAMS\|$TARGET_MAC\|$MIN_INTERVAL_MS\|$RX_CORES

mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT HUP INT TERM
exec >>"$LOG" 2>&1

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1"
}

file_md5() {
    "$MD5SUM" "$1" | awk '{print $1}'
}

add_bridge_interfaces() {
    for interface in $BRIDGE_INTERFACES; do
        "$BRCTL" addif "$BRIDGE" "$interface" 2>/dev/null || true
    done
}

quiesce_wireless_helpers() {
    for process in $QUIESCE_PROCESSES; do
        "$KILLALL" "$process" 2>/dev/null || true
    done
}

# restart_wireless launches several ASUS management helpers asynchronously.
# A one-shot kill is therefore racy: a late helper can issue a DHD control
# ioctl after continuous CSI has started and eventually wedge the AP radio.
# Keep those nonessential helpers suppressed for the lifetime of AP+CSI mode.
# Authentication, DHCP, bridging, and routing processes are not in the list.
start_quiesce_supervisor() {
    if [ -r "$QUIESCE_PID_FILE" ]; then
        supervisor_pid=$(cat "$QUIESCE_PID_FILE" 2>/dev/null || true)
        case "$supervisor_pid" in
            ''|*[!0-9]*) ;;
            *)
                if kill -0 "$supervisor_pid" 2>/dev/null; then
                    return 0
                fi
                ;;
        esac
    fi

    (
        trap 'rm -f "$QUIESCE_PID_FILE"; exit 0' HUP INT TERM EXIT
        while :; do
            quiesce_wireless_helpers
            "$SLEEP" "$QUIESCE_INTERVAL"
        done
    ) </dev/null >>"$LOG" 2>&1 &
    supervisor_pid=$!
    printf '%s\n' "$supervisor_pid" >"$QUIESCE_PID_FILE"
    log "quiesce_supervisor_started=1 pid=$supervisor_pid interval_seconds=$QUIESCE_INTERVAL"
}

persist_wireless_identity() {
    changed=0

    if [ "$("$NVRAM" get "${NVRAM_PREFIX}_ssid")" != "$SSID" ]; then
        "$NVRAM" set "${NVRAM_PREFIX}_ssid=$SSID"
        changed=1
    fi
    if [ "$("$NVRAM" get "${NVRAM_PREFIX}_bss_enabled")" != 1 ]; then
        "$NVRAM" set "${NVRAM_PREFIX}_bss_enabled=1"
        changed=1
    fi

    for prefix in $DISABLED_NVRAM_PREFIXES; do
        if [ "$("$NVRAM" get "${prefix}_ssid")" != "$SSID" ]; then
            "$NVRAM" set "${prefix}_ssid=$SSID"
            changed=1
        fi
        if [ "$("$NVRAM" get "${prefix}_bss_enabled")" != 0 ]; then
            "$NVRAM" set "${prefix}_bss_enabled=0"
            changed=1
        fi
    done

    if [ "$changed" = 1 ]; then
        "$NVRAM" commit
        log "wireless_identity_persisted ssid=$SSID interface=$RADIO_INTERFACE"
    fi
}

enforce_wireless_identity() {
    current_ssid=$("$WL" -i "$RADIO_INTERFACE" ssid 2>/dev/null) || return 1
    case "$current_ssid" in
        *\"$SSID\"*) ;;
        *) "$WL" -i "$RADIO_INTERFACE" ssid "$SSID" || return 1 ;;
    esac

    for interface in $DISABLED_INTERFACES; do
        current_ssid=$("$WL" -i "$interface" ssid 2>/dev/null) || return 1
        case "$current_ssid" in
            *\"$SSID\"*) ;;
            *) "$WL" -i "$interface" ssid "$SSID" || return 1 ;;
        esac
        if "$WL" -i "$interface" bss 2>/dev/null | grep -q '^up$'; then
            "$WL" -i "$interface" bss down || return 1
        fi
    done
}

configure_csi() {
    AP_CSI_INTERFACE="$RADIO_INTERFACE" \
        AP_CSI_WL="$WL" \
        AP_CSI_NEXUTIL="$NEXUTIL" \
        "$CONFIGURE" \
        "$CHANNEL" "$BANDWIDTH" "$TX_STREAMS" "$TARGET_MAC" \
        "$MIN_INTERVAL_MS" "$RX_CORES"
}

remember_configuration() {
    printf '%s\n' "$CONFIG_SIGNATURE" >"$CONFIG_SIGNATURE_FILE"
}

configuration_is_current() {
    [ -r "$CONFIG_SIGNATURE_FILE" ] \
        && [ "$(cat "$CONFIG_SIGNATURE_FILE" 2>/dev/null)" = "$CONFIG_SIGNATURE" ]
}

restore_stock() {
    reason=$1
    log "rollback_started reason=$reason"

    if ! "$RMMOD" dhd; then
        log "rollback_unload_failed=1 rebooting_to_stock=1"
        "$REBOOT"
        exit 1
    fi

    "$UMOUNT" "$MODULE_PATH" 2>/dev/null || true
    if [ "$(file_md5 "$MODULE_PATH")" != "$EXPECTED_STOCK" ]; then
        log "underlying_stock_invalid=1 using_backup=1"
        "$MOUNT" -o bind "$STOCK_BACKUP" "$MODULE_PATH" || {
            log "stock_backup_bind_failed=1 rebooting=1"
            "$REBOOT"
            exit 1
        }
    fi

    "$INSMOD" "$MODULE_PATH" || {
        log "stock_load_failed=1 rebooting=1"
        "$REBOOT"
        exit 1
    }
    "$SERVICE" restart_wireless || {
        log "stock_wireless_restart_failed=1 rebooting=1"
        "$REBOOT"
        exit 1
    }
    "$SLEEP" 25
    "$WL" -i "$RADIO_INTERFACE" monitor 0 2>/dev/null || true
    "$IFCONFIG" "$RADIO_INTERFACE" up 2>/dev/null || true
    add_bridge_interfaces
    log "rollback_complete=1"
    exit 1
}

[ "$(file_md5 "$CANDIDATE")" = "$EXPECTED_CANDIDATE" ] || {
    log "candidate_hash_invalid=1"
    exit 1
}
[ "$(file_md5 "$STOCK_BACKUP")" = "$EXPECTED_STOCK" ] || {
    log "stock_backup_hash_invalid=1"
    exit 1
}

persist_wireless_identity

current_hash=$(file_md5 "$MODULE_PATH")
if [ "$current_hash" = "$EXPECTED_CANDIDATE" ]; then
    if configuration_is_current; then
        start_quiesce_supervisor
        exit 0
    fi

    # A changed or lost signature must be applied from a clean stock-driver
    # boot. Never try to reconfigure the live AP+CSI driver in place.
    log "candidate_configuration_change_requires_reboot=1"
    exit 1
fi

[ "$current_hash" = "$EXPECTED_STOCK" ] || {
    log "module_hash_invalid hash=$current_hash"
    exit 1
}

"$WL" -i "$RADIO_INTERFACE" status >/dev/null 2>&1 || {
    log "stock_wireless_not_ready=1"
    exit 1
}

log "candidate_install_started=1"
quiesce_wireless_helpers
"$RMMOD" dhd || {
    log "stock_unload_failed=1"
    exit 1
}
"$UMOUNT" "$MODULE_PATH" 2>/dev/null || true
"$MOUNT" -o bind "$CANDIDATE" "$MODULE_PATH" || restore_stock candidate_bind_failed
"$INSMOD" "$MODULE_PATH" || restore_stock candidate_load_failed
"$SERVICE" restart_wireless || restore_stock wireless_restart_failed
quiesce_wireless_helpers

ready=0
attempt=0
while [ "$attempt" -lt 45 ]; do
    if "$WL" -i "$RADIO_INTERFACE" status >/dev/null 2>&1 \
        && "$WL" -i "$RADIO_INTERFACE" bss 2>/dev/null | grep -q '^up$' \
        && "$WL" -i "$RADIO_INTERFACE" chanspec 2>/dev/null | grep -F -q "$EXPECTED_CHANSPEC"; then
        ready=1
        break
    fi
    attempt=$((attempt + 1))
    "$SLEEP" 1
done
[ "$ready" = 1 ] || restore_stock radio_not_ready

"$WL" -i "$RADIO_INTERFACE" monitor 0 2>/dev/null || true
"$IFCONFIG" "$RADIO_INTERFACE" up 2>/dev/null || true
add_bridge_interfaces
enforce_wireless_identity || restore_stock wireless_identity_failed
configure_csi || restore_stock csi_configuration_failed

"$WL" -i "$RADIO_INTERFACE" bss | grep -q '^up$' || restore_stock ap_bss_down
"$WL" -i "$RADIO_INTERFACE" chanspec | grep -F -q "$EXPECTED_CHANSPEC" || restore_stock wrong_chanspec
"$NEXUTIL" -I "$RADIO_INTERFACE" -g501 -l2 | grep -q '01 00' || restore_stock csi_verification_failed
remember_configuration
start_quiesce_supervisor

log "candidate_install_complete=1 ap_mode=1 csi_enabled=1 interface=$RADIO_INTERFACE chanspec=$EXPECTED_CHANSPEC"
exit 0
