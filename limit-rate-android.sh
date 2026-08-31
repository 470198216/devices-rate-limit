#!/system/bin/sh
# Android tc: limit upload (egress) and/or download (ingress).
# Needs root. Copy with Unix LF, then:
#   su -c 'sh /sdcard/limit-rate-android.sh apply 10'
#   su -c 'sh /sdcard/limit-rate-android.sh apply 10 down'
#   su -c 'sh /sdcard/limit-rate-android.sh apply 10 up'
#   su -c 'sh /sdcard/limit-rate-android.sh remove'
#   su -c 'sh /sdcard/limit-rate-android.sh status'
#
# Modern Android (clsact + existing ifb0): do NOT add another ingress qdisc.
# Reuse clsact ingress hook and ifb0.

ACTION="$1"
ARG2="$2"
ARG3="$3"
RATE=10
DIR=both
ING_PRIO=99

if [ -z "$ACTION" ]; then
  ACTION=status
fi

case "$ARG2" in
  "")
    ;;
  up|down|both)
    DIR="$ARG2"
    ;;
  *[!0-9]*)
    echo "bad rate: $ARG2"
    exit 1
    ;;
  *)
    RATE="$ARG2"
    ;;
esac

case "$ARG3" in
  up|down|both)
    DIR="$ARG3"
    ;;
esac

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
IFB=ifb0

has_clsact() {
  run_tc qdisc show dev "$IFACE" 2>/dev/null | grep clsact >/dev/null 2>&1
}

do_status() {
  echo "uid=`id -u 2>/dev/null` tc=$TCPATH iface=$IFACE rate=$RATE_SPEC dir=$DIR"
  if [ -n "$IFACE" ]; then
    if [ -n "$TCPATH" ]; then
      echo "---- $IFACE qdisc ----"
      run_tc qdisc show dev "$IFACE" 2>/dev/null
      echo "---- $IFACE filter ingress ----"
      run_tc filter show dev "$IFACE" ingress 2>/dev/null
      echo "---- $IFACE filter parent ffff:fff1 (clsact ingress) ----"
      run_tc filter show dev "$IFACE" parent ffff:fff1 2>/dev/null
      echo "---- $IFACE filter parent ffff: ----"
      run_tc filter show dev "$IFACE" parent ffff: 2>/dev/null
    fi
  fi
  if ip link show "$IFB" >/dev/null 2>&1; then
    echo "---- $IFB ----"
    ip link show "$IFB" 2>/dev/null
    run_tc qdisc show dev "$IFB" 2>/dev/null
  fi
}

del_our_filters() {
  run_tc filter del dev "$IFACE" ingress prio "$ING_PRIO" 2>/dev/null
  run_tc filter del dev "$IFACE" parent ffff:fff1 prio "$ING_PRIO" 2>/dev/null
  run_tc filter del dev "$IFACE" parent ffff: prio "$ING_PRIO" 2>/dev/null
}

clear_down() {
  del_our_filters
  if has_clsact; then
    :
  else
    run_tc qdisc del dev "$IFACE" ingress 2>/dev/null
  fi
  if ip link show "$IFB" >/dev/null 2>&1; then
    run_tc qdisc replace dev "$IFB" root pfifo 2>/dev/null
    run_tc qdisc del dev "$IFB" root 2>/dev/null
  fi
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
  clear_down
  echo "cleared $IFACE (up+down); kept system clsact/ifb0"
}

do_apply_up() {
  run_tc qdisc del dev "$IFACE" root 2>/dev/null
  run_tc qdisc add dev "$IFACE" root tbf rate "$RATE_SPEC" burst 2kb latency 400ms
  if [ $? -ne 0 ]; then
    echo "UPLOAD failed (tbf)"
    return 1
  fi
  echo "UPLOAD ok: $IFACE egress $RATE_SPEC"
  return 0
}

ensure_ifb() {
  modprobe ifb 2>/dev/null
  if ip link show "$IFB" >/dev/null 2>&1; then
    ip link set "$IFB" up 2>/dev/null
    echo "reuse existing $IFB"
    return 0
  fi
  ip link add "$IFB" type ifb 2>/dev/null
  ip link set "$IFB" up 2>/dev/null
  if ip link show "$IFB" >/dev/null 2>&1; then
    echo "created $IFB"
    return 0
  fi
  echo "no $IFB device"
  return 1
}

ensure_ingress_hook() {
  if has_clsact; then
    echo "ingress hook: existing clsact"
    return 0
  fi
  run_tc qdisc add dev "$IFACE" clsact 2>/dev/null
  if has_clsact; then
    echo "ingress hook: added clsact"
    return 0
  fi
  run_tc qdisc add dev "$IFACE" handle ffff: ingress 2>/dev/null
  if [ $? -eq 0 ]; then
    echo "ingress hook: classic ingress"
    return 0
  fi
  echo "no ingress hook (clsact/ingress add failed)"
  return 1
}

add_redirect_filter() {
  run_tc filter add dev "$IFACE" ingress protocol all prio "$ING_PRIO" u32 match u32 0 0 action mirred egress redirect dev "$IFB" 2>/dev/null
  if [ $? -eq 0 ]; then
    echo "redirect filter: ingress -> $IFB"
    return 0
  fi
  run_tc filter add dev "$IFACE" parent ffff:fff1 protocol all prio "$ING_PRIO" u32 match u32 0 0 action mirred egress redirect dev "$IFB" 2>/dev/null
  if [ $? -eq 0 ]; then
    echo "redirect filter: ffff:fff1 -> $IFB"
    return 0
  fi
  run_tc filter add dev "$IFACE" parent ffff: protocol all prio "$ING_PRIO" u32 match u32 0 0 action mirred egress redirect dev "$IFB" 2>/dev/null
  if [ $? -eq 0 ]; then
    echo "redirect filter: ffff: -> $IFB"
    return 0
  fi
  return 1
}

add_police_filter() {
  run_tc filter add dev "$IFACE" ingress protocol all prio "$ING_PRIO" u32 match u32 0 0 police rate "$RATE_SPEC" burst 12k drop 2>/dev/null
  if [ $? -eq 0 ]; then
    echo "DOWNLOAD ok: clsact/ingress police all $RATE_SPEC"
    return 0
  fi
  run_tc filter add dev "$IFACE" parent ffff:fff1 protocol all prio "$ING_PRIO" u32 match u32 0 0 police rate "$RATE_SPEC" burst 12k drop 2>/dev/null
  if [ $? -eq 0 ]; then
    echo "DOWNLOAD ok: ffff:fff1 police all $RATE_SPEC"
    return 0
  fi
  run_tc filter add dev "$IFACE" parent ffff:fff1 protocol ip prio "$ING_PRIO" u32 match u32 0 0 police rate "$RATE_SPEC" burst 12k drop 2>/dev/null
  ip_ok=$?
  run_tc filter add dev "$IFACE" parent ffff:fff1 protocol ipv6 prio "$((ING_PRIO + 1))" u32 match u32 0 0 police rate "$RATE_SPEC" burst 12k drop 2>/dev/null
  if [ "$ip_ok" -eq 0 ]; then
    echo "DOWNLOAD ok: ffff:fff1 police ipv4 $RATE_SPEC"
    return 0
  fi
  run_tc filter add dev "$IFACE" parent ffff: protocol ip prio "$ING_PRIO" u32 match u32 0 0 police rate "$RATE_SPEC" burst 12k drop 2>/dev/null
  if [ $? -eq 0 ]; then
    echo "DOWNLOAD ok: parent ffff: police ipv4 $RATE_SPEC"
    return 0
  fi
  return 1
}

try_ifb() {
  ensure_ifb
  if [ $? -ne 0 ]; then
    return 1
  fi
  ensure_ingress_hook
  if [ $? -ne 0 ]; then
    return 1
  fi
  del_our_filters
  run_tc qdisc replace dev "$IFB" root tbf rate "$RATE_SPEC" burst 2kb latency 400ms
  if [ $? -ne 0 ]; then
    run_tc qdisc del dev "$IFB" root 2>/dev/null
    run_tc qdisc add dev "$IFB" root tbf rate "$RATE_SPEC" burst 2kb latency 400ms
    if [ $? -ne 0 ]; then
      echo "cannot put tbf on $IFB"
      return 1
    fi
  fi
  add_redirect_filter
  if [ $? -ne 0 ]; then
    echo "mirred redirect not supported"
    return 1
  fi
  echo "DOWNLOAD ok: $IFACE ingress -> $IFB tbf $RATE_SPEC"
  return 0
}

try_police() {
  ensure_ingress_hook
  if [ $? -ne 0 ]; then
    echo "DOWNLOAD failed: no ingress/clsact hook"
    return 1
  fi
  del_our_filters
  add_police_filter
  if [ $? -eq 0 ]; then
    return 0
  fi
  echo "DOWNLOAD failed: no mirred and police/filter not supported"
  echo "use NetValve app for download"
  return 1
}

do_apply_down() {
  del_our_filters
  try_ifb
  if [ $? -eq 0 ]; then
    return 0
  fi
  echo "ifb redirect failed, try ingress police"
  try_police
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
  if [ "$DIR" = up ]; then
    do_apply_up
    return
  fi
  if [ "$DIR" = down ]; then
    do_apply_down
    return
  fi
  do_apply_up
  do_apply_down
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
    echo "usage: $0 apply|remove|status [kbit] [up|down|both]"
    exit 1
    ;;
esac
