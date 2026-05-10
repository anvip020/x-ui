#!/bin/bash

DB="/root/ip_limit.db"

echo "============================"
echo "IP 上传限速工具（修复版）"
echo "============================"

echo "当前网卡："
ip -o link show | awk -F': ' '{print $2}' | grep -v lo
echo ""

read -p "请输入网卡: " IFACE

init_tc() {
    modprobe ifb 2>/dev/null

    tc qdisc del dev "$IFACE" root 2>/dev/null
    tc qdisc add dev "$IFACE" root handle 1: htb default 999
}

add_rule() {
    init_tc

    CLASS=10

    while true; do
        read -p "请输入IP/CIDR（done结束）: " IP
        [[ "$IP" == "done" ]] && break

        read -p "限速(Mbps，直接数字): " RATE

        if [[ "$RATE" =~ ^[0-9]+$ ]]; then
            RATE="${RATE}mbit"
        fi

        # 删除旧规则
        tc class del dev "$IFACE" classid 1:$CLASS 2>/dev/null

        # 添加 class
        tc class add dev "$IFACE" parent 1: classid 1:$CLASS htb rate "$RATE"

        # 添加 filter
        tc filter add dev "$IFACE" protocol ip parent 1: prio 1 u32 match ip src "$IP" flowid 1:$CLASS

        echo "$IP|$RATE|$CLASS" >> "$DB"

        echo "OK: $IP -> $RATE"
        CLASS=$((CLASS+1))
    done
}

show_rules() {
    echo "===== 当前规则 ====="
    cat "$DB" 2>/dev/null || echo "无规则"
}

delete_rule() {
    show_rules
    read -p "删除哪个IP: " IP

    CLASS=$(grep "$IP" "$DB" | cut -d"|" -f3)

    tc class del dev "$IFACE" classid 1:$CLASS 2>/dev/null
    tc filter del dev "$IFACE" parent 1: prio 1 u32 match ip src "$IP" 2>/dev/null

    grep -v "$IP" "$DB" > /tmp/db && mv /tmp/db "$DB"

    echo "已删除 $IP"
}

echo ""
echo "1) 添加"
echo "2) 查看"
echo "3) 删除"
read -p "选择: " opt

case $opt in
    1) add_rule ;;
    2) show_rules ;;
    3) delete_rule ;;
esac
