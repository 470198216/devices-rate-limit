#!/system/bin/sh
# Android tc rate limit. Needs root. Default 10kbit.
# Copy this file to the device, then:
#   su -c 'sh /sdcard/limit-rate-android.sh apply 10'
#   su -c 'sh /sdcard/limit-rate-android.sh remove'
#   su -c 'sh /sdcard/limit-rate-android.sh status'

ACTION="$1"
RATE="$2"
if [ -z "$ACTION" ]; then
  ACTION=status
fi
if [ -z "$RATE" ]; then
  RATE=10
fi

tc_bin() {
  if [ -x /system/bin/tc ]; then
    echo /system/bin/tc
    return
  fi
  if [ -x /system/xbin/tc ]; then
    echo /system/xbin/tc
    return
  fi
  if [ -x /system/bin/busybox ]; then
    echo /system/bin/busybox
    return
  fi
  echo ""
}

iface_default() {
  ip route show default 2>/dev/null | awk '{
    for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }
  }'
}

need_root() {
  uid=`id -u 2>/dev/null`
  if [ -z "$uid" ]; then
    uid=1
  fi
  if [ "$uid" != 0 ]; then
    echo "need root: su -c 'sh $0 apply 10'"
    exit 1
  fi
}

run_tc() {
  if [ "$TCBASE" = busybox ]; then
    "$TCPATH" tc "$@"
  else
    "$TCPATH" "$@"
  fi
}

TCPATH=`tc_bin`
TCBASE=`basename "$TCPATH" 2>/dev/null`
if [ -z "$IFACE" ]; then
  IFACE=`iface_default`
fi
RATE_SPEC=${RATE}kbit

do_status() {
  echo "uid=`id -u 2>/dev/null` tc=$TCPATH iface=$IFACE"
  if [ -n "$IFACE" ]; then
    if [ -n "$TCPATH" ]; then
      echo "---- $IFACE ----"
      run_tc qdisc show dev "$IFACE" 2>/dev/null
    fi
  fi
  echo "up links:"
  ip -o link show up 2>/dev/null
}

do_remove() {
  need_root
  if [ -z "$TCPATH" ]; then
    echo "tc not found"
    exit 1
  fi
  if [ -z "$IFACE" ]; then
    echo "no default iface, run: ip route"
    exit 1
  fi
  run_tc qdisc del dev "$IFACE" root 2>/dev/null
  run_tc qdisc del dev "$IFACE" ingress 2>/dev/null
  echo "cleared $IFACE"
}

do_apply() {
  need_root
  if [ -z "$TCPATH" ]; then
    echo "tc not found"
    exit 1
  fi
  if [ -z "$IFACE" ]; then
    echo "no default iface"
    exit 1
  fi
  run_tc qdisc del dev "$IFACE" root 2>/dev/null
  run_tc qdisc add dev "$IFACE" root tbf rate "$RATE_SPEC" burst 2kb latency 400ms
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "tbf failed, use NetValve app instead"
    exit 1
  fi
  echo "limited egress $IFACE -> $RATE_SPEC"
}

case "$ACTION" in
  apply)
    do_apply
    do_status
    ;;
  remove)
    do_remove
    do_status
    ;;
  status)
    do_status
    ;;
  *)
    echo "usage: $0 apply|remove|status [kbit]"
    exit 1
    ;;
esac
