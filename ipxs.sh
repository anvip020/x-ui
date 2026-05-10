modify_limit() {

    if [ ! -f "$DB_FILE" ] || [ ! -s "$DB_FILE" ]; then
        echo "当前没有限速规则"
        exit 0
    fi

    show_limits

    echo ""

    read -p "请输入要修改的序号: " NUM

    OLD_LINE=$(sed -n "${NUM}p" $DB_FILE)

    if [ -z "$OLD_LINE" ]; then
        echo "序号不存在"
        exit 1
    fi

    OLD_DEV=$(echo $OLD_LINE | cut -d "|" -f1)
    OLD_IP=$(echo $OLD_LINE | cut -d "|" -f2)
    OLD_SPEED=$(echo $OLD_LINE | cut -d "|" -f3)

    echo ""
    echo "当前配置："
    echo "网卡: $OLD_DEV"
    echo "IP: $OLD_IP"
    echo "限速: ${OLD_SPEED}Mbps"
    echo ""

    read -p "请输入新的网卡(直接回车保持不变): " NEW_DEV
    read -p "请输入新的IP(直接回车保持不变): " NEW_IP
    read -p "请输入新的限速Mbps数字(直接回车保持不变): " NEW_SPEED

    [ -z "$NEW_DEV" ] && NEW_DEV=$OLD_DEV
    [ -z "$NEW_IP" ] && NEW_IP=$OLD_IP
    [ -z "$NEW_SPEED" ] && NEW_SPEED=$OLD_SPEED

    sed -i "${NUM}s/.*/${NEW_DEV}|${NEW_IP}|${NEW_SPEED}/" $DB_FILE

    tc qdisc del dev ifb0 root 2>/dev/null

    init_ifb

    apply_all_limits

    echo ""
    echo "======================================"
    echo "修改成功"
    echo "======================================"
    echo "网卡: $NEW_DEV"
    echo "IP: $NEW_IP"
    echo "限速: ${NEW_SPEED}Mbps"
    echo ""
}
