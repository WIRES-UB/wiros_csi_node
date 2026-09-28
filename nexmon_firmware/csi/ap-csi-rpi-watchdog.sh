#!/bin/sh
# Run on the RPi paired with whichever router has the AP+CSI role. The router
# boots its stock driver first; this watchdog performs the tested late switch.
set -u

ROUTER_HOST=${AP_CSI_ROUTER_HOST:-192.168.48.6}
SOURCE_IP=${AP_CSI_SOURCE_IP:-192.168.48.20}
LINK_INTERFACE=${AP_CSI_LINK_INTERFACE:-eth0}
ROUTER_USER=${AP_CSI_ROUTER_USER:-wiloc}
ROUTER_LABEL=${AP_CSI_ROUTER_LABEL:-AP+CSI router}
PASSWORD_FILE=${AP_CSI_PASSWORD_FILE:-/home/wiloc/.config/wiros/ap_csi_router_password}
KNOWN_HOSTS=${AP_CSI_KNOWN_HOSTS:-/home/wiloc/.ssh/ap_csi_router_known_hosts}
REMOTE_COMMAND=${AP_CSI_REMOTE_COMMAND:-/jffs/csi/ap-csi-autostart.sh}
RADIO_INTERFACE=${AP_CSI_RADIO_INTERFACE:-eth6}
BOOT_SETTLE=${AP_CSI_BOOT_SETTLE:-120}
INTERVAL=${AP_CSI_HEALTH_INTERVAL:-60}
RETRY_DELAY=${AP_CSI_RETRY_DELAY:-20}
COMMAND_TIMEOUT=${AP_CSI_COMMAND_TIMEOUT:-180}
HEALTH_TIMEOUT=${AP_CSI_HEALTH_TIMEOUT:-20}
MAX_FAILURES=${AP_CSI_MAX_FAILURES:-3}

SSH=${AP_CSI_SSH:-/usr/bin/ssh}
SSHPASS=${AP_CSI_SSHPASS:-/usr/bin/sshpass}
PING=${AP_CSI_PING:-/usr/bin/ping}
TIMEOUT=${AP_CSI_TIMEOUT:-/usr/bin/timeout}
SLEEP=${AP_CSI_SLEEP:-/usr/bin/sleep}
LOGGER=${AP_CSI_LOGGER:-/usr/bin/logger}

failures=0
last_state=
configured_router_uptime=

announce() {
    state=$1
    message=$2
    if [ "$state" != "$last_state" ]; then
        printf '%s\n' "$message"
        "$LOGGER" -t ap-csi-rpi-watchdog -- "$message"
        last_state=$state
    fi
}

router_ssh() {
    command_timeout=${2:-$COMMAND_TIMEOUT}
    "$TIMEOUT" --signal=TERM --kill-after=10 "$command_timeout" \
        "$SSHPASS" -f "$PASSWORD_FILE" "$SSH" -n \
        -b "$SOURCE_IP" \
        -o BatchMode=no \
        -o ConnectTimeout=5 \
        -o ConnectionAttempts=1 \
        -o HostkeyAlgorithms=+ssh-rsa \
        -o PubkeyAuthentication=no \
        -o PreferredAuthentications=password,keyboard-interactive \
        -o NumberOfPasswordPrompts=1 \
        -o ServerAliveInterval=10 \
        -o ServerAliveCountMax=2 \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$KNOWN_HOSTS" \
        "$ROUTER_USER@$ROUTER_HOST" "$1"
}

router_health_check() {
    # Do not issue wl/nexutil ioctls here.  The concurrent firmware can stop
    # answering them even while forwarding traffic, and probing a wedged radio
    # can make recovery worse.  These kernel/bridge checks are read-only and
    # detect the observed failure mode where eth6 fell out of br0.
    router_ssh "
        [ -d '/sys/class/net/$RADIO_INTERFACE' ] || exit 10
        /bin/grep -q '^dhd ' /proc/modules || exit 11
        /sbin/brctl show br0 2>/dev/null | /bin/grep -qw '$RADIO_INTERFACE' || exit 12
    " "$HEALTH_TIMEOUT"
}

reboot_router() {
    announce rebooting "$ROUTER_LABEL CSI driver unhealthy; requesting router reboot"
    "$TIMEOUT" --signal=TERM --kill-after=5 15 \
        "$SSHPASS" -f "$PASSWORD_FILE" "$SSH" -n \
        -b "$SOURCE_IP" \
        -o BatchMode=no \
        -o ConnectTimeout=5 \
        -o HostkeyAlgorithms=+ssh-rsa \
        -o PubkeyAuthentication=no \
        -o PreferredAuthentications=password,keyboard-interactive \
        -o NumberOfPasswordPrompts=1 \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$KNOWN_HOSTS" \
        "$ROUTER_USER@$ROUTER_HOST" /sbin/reboot || true
    "$SLEEP" "$RETRY_DELAY"
    failures=0
}

while :; do
    if [ ! -x "$SSHPASS" ] || [ ! -r "$PASSWORD_FILE" ]; then
        announce credentials_missing "Waiting for $ROUTER_LABEL credentials"
        "$SLEEP" "$RETRY_DELAY"
        continue
    fi

    if [ ! -r "/sys/class/net/$LINK_INTERFACE/carrier" ] \
        || [ "$(cat "/sys/class/net/$LINK_INTERFACE/carrier" 2>/dev/null)" != 1 ]; then
        announce cable_down "Waiting for $ROUTER_LABEL Ethernet cable on $LINK_INTERFACE"
        "$SLEEP" "$RETRY_DELAY"
        continue
    fi

    if ! "$PING" -I "$LINK_INTERFACE" -c 1 -W 2 "$ROUTER_HOST" >/dev/null 2>&1; then
        announce router_down "Waiting for $ROUTER_LABEL at $ROUTER_HOST"
        "$SLEEP" "$RETRY_DELAY"
        continue
    fi

    router_uptime=$(router_ssh "cut -d. -f1 /proc/uptime" 2>/dev/null) || router_uptime=
    case "$router_uptime" in
        ''|*[!0-9]*)
            announce ssh_wait "Waiting for SSH on $ROUTER_LABEL"
            "$SLEEP" "$RETRY_DELAY"
            continue
            ;;
    esac
    if [ "$router_uptime" -lt "$BOOT_SETTLE" ]; then
        announce boot_settle "Waiting for $ROUTER_LABEL stock boot to settle (${router_uptime}s/${BOOT_SETTLE}s)"
        "$SLEEP" "$RETRY_DELAY"
        continue
    fi

    # Once configuration succeeds, probe the live AP and CSI state on every
    # interval.  Do not re-run the installer during the same boot: a wedged
    # firmware/driver needs a controlled reboot, not more live driver changes.
    if [ -n "$configured_router_uptime" ] \
        && [ "$router_uptime" -ge "$configured_router_uptime" ]; then
        if router_health_check >/dev/null 2>&1; then
            failures=0
            announce healthy "$ROUTER_LABEL radio interface and bridge are healthy"
            "$SLEEP" "$INTERVAL"
            continue
        else
            rc=$?
            failures=$((failures + 1))
            announce health_failed "$ROUTER_LABEL live AP+CSI health check failed (rc=$rc, attempt=$failures/$MAX_FAILURES)"
            if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ] \
                || [ "$failures" -ge "$MAX_FAILURES" ]; then
                reboot_router
            else
                "$SLEEP" "$RETRY_DELAY"
            fi
            continue
        fi
    fi

    if router_ssh "$REMOTE_COMMAND"; then
        configured_router_uptime=$router_uptime
        failures=0
        announce healthy "$ROUTER_LABEL CSI driver/channel/filter are healthy"
        "$SLEEP" "$INTERVAL"
        continue
    else
        rc=$?
    fi

    failures=$((failures + 1))
    announce install_failed "$ROUTER_LABEL AP+CSI check failed (rc=$rc, attempt=$failures/$MAX_FAILURES)"

    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ] || [ "$failures" -ge "$MAX_FAILURES" ]; then
        reboot_router
    else
        "$SLEEP" "$RETRY_DELAY"
    fi
done
