#!/usr/bin/env bash
# 在本机用 tc 限速（不改路由器）。默认 10kbit。
# 需要 root。限出口；加 --down 时用 ifb 再限入口（下载）。
#
#   sudo ./limit-rate.sh apply          # 出口 10kbit
#   sudo ./limit-rate.sh apply 10 --down
#   sudo ./limit-rate.sh status
#   sudo ./limit-rate.sh remove

set -euo pipefail

ACTION="${1:-status}"
RATE="${2:-10}"
DO_DOWN=0
for a in "$@"; do
  [[ "$a" == "--down" ]] && DO_DOWN=1
done

if [[ "$RATE" == "--down" ]]; then
  RATE=10
fi

iface_default() {
  ip route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

IFACE="${IFACE:-$(iface_default)}"
IFB="${IFB:-ifb0}"
RATE_SPEC="${RATE}kbit"

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "请用 sudo 运行: sudo $0 $*"
    exit 1
  fi
}

status() {
  echo "默认网口: ${IFACE:-未找到}"
  if [[ -n "${IFACE:-}" ]]; then
    echo "---- $IFACE (出口) ----"
    tc -s qdisc show dev "$IFACE" || true
    echo "---- $IFACE ingress ----"
    tc -s qdisc show dev "$IFACE" ingress 2>/dev/null || true
  fi
  if ip link show "$IFB" &>/dev/null; then
    echo "---- $IFB (入口镜像) ----"
    tc -s qdisc show dev "$IFB" || true
  fi
}

remove() {
  need_root
  [[ -n "${IFACE:-}" ]] || { echo "找不到默认网口"; exit 1; }
  tc qdisc del dev "$IFACE" root 2>/dev/null || true
  tc qdisc del dev "$IFACE" ingress 2>/dev/null || true
  if ip link show "$IFB" &>/dev/null; then
    tc qdisc del dev "$IFB" root 2>/dev/null || true
    ip link set "$IFB" down 2>/dev/null || true
  fi
  echo "已清除 $IFACE 上的本机限速"
}

apply() {
  need_root
  [[ -n "${IFACE:-}" ]] || { echo "找不到默认网口"; exit 1; }
  remove >/dev/null
  tc qdisc add dev "$IFACE" root tbf rate "$RATE_SPEC" burst 2kb latency 400ms
  echo "已限出口: $IFACE -> $RATE_SPEC"

  if [[ "$DO_DOWN" -eq 1 ]]; then
    modprobe ifb numifbs=1
    ip link set "$IFB" up
    tc qdisc add dev "$IFACE" handle ffff: ingress
    tc filter add dev "$IFACE" parent ffff: protocol all u32 match u32 0 0 \
      action mirred egress redirect dev "$IFB"
    tc qdisc add dev "$IFB" root tbf rate "$RATE_SPEC" burst 2kb latency 400ms
    echo "已限入口(下载): $IFACE -> $IFB -> $RATE_SPEC"
  else
    echo "未限下载。需要对称限速请加 --down"
  fi
}

case "$ACTION" in
  apply) apply; status ;;
  remove) remove; status ;;
  status) status ;;
  *) echo "用法: $0 apply|remove|status [kbit] [--down]"; exit 1 ;;
esac
