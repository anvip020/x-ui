# IPsec 通道 QoS 限速脚本（按隧道公网IP限速）

适用：

* strongSwan / IPsec
* Linux tc + HTB
* Ubuntu / Debian

功能：

* 自动读取 IPsec 通道
* 自动显示序号
* 选择序号即可限速
* 支持新增 / 修改 / 删除
* 支持恢复规则
* 真正作用于 IPsec 外层公网流量

---

# 保存脚本

保存为：

```bash
/usr/local/sbin/ipsec-qos.sh
```

赋予权限：

```bash
chmod +x /usr/local/sbin/ipsec-qos.sh
```

运行：

```bash
bash /usr/local/sbin/ipsec-qos.sh
```

---

# 完整脚本

```bash
#!/usr/bin/env bash

CONFIG="/etc/ipsec-qos.conf"
INTERFACE=$(ip route | awk '/default/ {print $5}' | head -1)
IFACE="$INTERFACE"

mkdir -p /etc
[ -f "$CONFIG" ] || touch "$CONFIG"

# =====================================================
# 初始化 tc
# =====================================================
init_tc() {

    tc qdisc del dev $IFACE root 2>/dev/null

    tc qdisc add dev $IFACE root handle 1: htb default 999

    tc class add dev $IFACE parent 1: classid 1:1 \
        htb rate 1000mbit ceil 1000mbit

    tc class add dev $IFACE parent 1:1 classid 1:999 \
        htb rate 1000mbit ceil 1000mbit
}

# =====================================================
# 读取 IPsec tunnel
# =====================================================
load_tunnels() {

    mapfile -t TUNNELS < <(
        ip xfrm state | awk '
            /src .* dst .*proto esp/ {
                src=""
                dst=""

                for(i=1;i<=NF;i++) {
                    if($i=="src") src=$(i+1)
                    if($i=="dst") dst=$(i+1)
                }

                if(src!="" && dst!="")
                    print dst
            }
        ' | sort -u
    )
}

# =====================================================
# 显示 tunnel 列表
# =====================================================
show_tunnels() {

    load_tunnels

    echo ""
    echo "===== 当前 IPsec 通道 ====="
    echo ""

    if [ ${#TUNNELS[@]} -eq 0 ]; then
        echo "未发现 IPsec tunnel"
        return 1
    fi

    for i in "${!TUNNELS[@]}"; do
        printf "%2d) %s\n" "$((i+1))" "${TUNNELS[$i]}"
    done

    echo ""
}

# =====================================================
# 计算 ceil
# =====================================================
calc_ceil() {
    local rate=$1
    local burst=$2

    echo $(( rate * (100 + burst) / 100 ))
}

# =====================================================
# 获取下一个 class id
# =====================================================
get_next_id() {

    last=$(awk -F'|' 'NF{print $2}' $CONFIG | sort -n | tail -1)

    id=$(( ${last:-9} + 1 ))

    [ $id -lt 10 ] && id=10

    echo $id
}

# =====================================================
# 应用规则
# =====================================================
apply_rule() {

    local peer_ip=$1
    local id=$2
    local rate=$3
    local burst=$4

    ceil=$(calc_ceil $rate $burst)

    tc class add dev $IFACE parent 1:1 classid 1:$id \
        htb rate ${rate}mbit ceil ${ceil}mbit burst 15k cburst 15k 2>/dev/null

    tc filter add dev $IFACE parent 1: protocol ip prio $id u32 \
        match ip dst ${peer_ip}/32 flowid 1:$id 2>/dev/null

    echo "✔ 已应用: $peer_ip -> ${rate}Mbps (Burst ${ceil}Mbps)"
}

# =====================================================
# 恢复规则
# =====================================================
restore_rules() {

    [ ! -s "$CONFIG" ] && return

    while IFS='|' read -r peer id rate burst; do

        [ -z "$peer" ] && continue

        apply_rule "$peer" "$id" "$rate" "$burst"

    done < "$CONFIG"
}

# =====================================================
# 添加规则
# =====================================================
add_rule() {

    show_tunnels || return

    read -p "选择 tunnel 序号: " num

    if ! echo "$num" | grep -qE '^[0-9]+$'; then
        echo "无效序号"
        return
    fi

    peer_ip=${TUNNELS[$((num-1))]}

    if [ -z "$peer_ip" ]; then
        echo "序号不存在"
        return
    fi

    if grep -q "^${peer_ip}|" $CONFIG; then
        echo "该 tunnel 已存在规则"
        return
    fi

    read -p "限速 Mbps: " rate

    if ! echo "$rate" | grep -qE '^[0-9]+$'; then
        echo "限速值无效"
        return
    fi

    read -p "突发百分比 (建议20): " burst

    if ! echo "$burst" | grep -qE '^[0-9]+$'; then
        echo "突发值无效"
        return
    fi

    id=$(get_next_id)

    echo "${peer_ip}|${id}|${rate}|${burst}" >> $CONFIG

    apply_rule "$peer_ip" "$id" "$rate" "$burst"
}

# =====================================================
# 查看规则
# =====================================================
show_rules() {

    echo ""
    echo "===== 当前限速规则 ====="
    echo ""

    if [ ! -s "$CONFIG" ]; then
        echo "暂无规则"
        return
    fi

    printf "%-4s %-18s %-8s %-8s %-10s\n" \
        "ID" "Tunnel IP" "Rate" "Burst" "Ceil"

    awk -F'|' '{
        ceil=int($3*(100+$4)/100)

        printf "%-4s %-18s %-8s %-8s %-10s\n",
        $2,$1,$3"M",$4"%",ceil"M"
    }' $CONFIG

    echo ""
    tc -s class show dev $IFACE
}

# =====================================================
# 删除规则
# =====================================================
delete_rule() {

    if [ ! -s "$CONFIG" ]; then
        echo "暂无规则"
        return
    fi

    nl -w2 -s') ' $CONFIG

    echo ""

    read -p "输入删除序号: " num

    line=$(sed -n "${num}p" $CONFIG)

    [ -z "$line" ] && echo "无效" && return

    peer=$(echo "$line" | cut -d'|' -f1)
    id=$(echo "$line" | cut -d'|' -f2)

    tc filter del dev $IFACE parent 1: prio $id 2>/dev/null

    tc class del dev $IFACE classid 1:$id 2>/dev/null

    sed -i "${num}d" $CONFIG

    echo "✔ 已删除: $peer"
}

# =====================================================
# 菜单
# =====================================================
menu() {

    while true; do

        echo ""
        echo "============================"
        echo " IPsec QoS 限速系统"
        echo "============================"
        echo "1) 添加限速规则"
        echo "2) 查看限速规则"
        echo "3) 删除限速规则"
        echo "4) 退出"
        echo "============================"

        echo ""

        read -p "选择: " opt

        case $opt in

            1)
                add_rule
                ;;

            2)
                show_rules
                ;;

            3)
                delete_rule
                ;;

            4)
                exit 0
                ;;

            *)
                echo "无效选项"
                ;;

        esac

    done
}

# =====================================================
# 启动
# =====================================================
init_tc
restore_rules
menu
```

---

# 使用说明

## 1. 查看 IPsec 通道

会自动读取：

```bash
ip xfrm state
```

自动列出：

```text
1) 38.150.12.82
2) 103.233.179.31
```

---

## 2. 添加限速

例如：

```text
选择 tunnel 序号: 1
限速 Mbps: 10
突发百分比: 20
```

实际效果：

```text
正常带宽: 10Mbps
短时突发: 12Mbps
```

---

# 查看是否生效

```bash
tc -s class show dev eth0
```

如果看到：

```text
overlimits > 0
```

说明已经真正限速。

---

# 推荐优化（非常重要）

建议关闭网卡 offload：

```bash
ethtool -K eth0 gro off gso off tso off
```

否则高流量下 tc 有概率被绕过。
