#!/bin/sh
# OpenWrt 24.x (fw4/nftables) + AmneziaWG 2.0 (awg0 + awg1)
# Раздельная маршрутизация через nftsets. WAN (L2TP/PPPoE/DHCP) не трогается.

GREEN='\033[32;1m'
RED='\033[31;1m'
BLUE='\033[34;1m'
YELLOW='\033[33;1m'
NC='\033[0m'

source /etc/os-release
VERSION_ID=$(echo "$VERSION" | awk -F. '{print $1}')
[ "$VERSION_ID" -ne 24 ] && { echo -e "${RED}Скрипт только для OpenWrt 24.x (fw4/nftables)${NC}"; exit 1; }

MODEL=$(cat /tmp/sysinfo/model 2>/dev/null || echo "Unknown")
echo -e "${BLUE}Model: $MODEL${NC}"
echo -e "${BLUE}Version: $OPENWRT_RELEASE${NC}"
echo -e "${RED}Все действия нельзя откатить автоматически.${NC}"

PKG_MANAGER="opkg"
command -v apk >/dev/null 2>&1 && PKG_MANAGER="apk"

check_repo() {
    echo -e "${GREEN}Обновление репозиториев...${NC}"
    $PKG_MANAGER update || { echo -e "${RED}Нет доступа к репозиториям${NC}"; exit 1; }
}

install_base() {
    for pkg in curl nano; do
        if $PKG_MANAGER list-installed 2>/dev/null | grep -q "^$pkg "; then
            echo -e "${GREEN}$pkg уже установлен${NC}"
        else
            echo -e "${GREEN}Установка $pkg...${NC}"
            $PKG_MANAGER install "$pkg"
        fi
    done
}

install_awg_packages() {
    if $PKG_MANAGER list-installed 2>/dev/null | grep -q amneziawg-tools && \
       $PKG_MANAGER list-installed 2>/dev/null | grep -q kmod-amneziawg && \
       $PKG_MANAGER list-installed 2>/dev/null | grep -q luci-app-amneziawg; then
        echo -e "${GREEN}AmneziaWG уже установлен${NC}"
        return
    fi

    echo -e "${GREEN}Попытка установить AmneziaWG из репозитория...${NC}"
    $PKG_MANAGER install amneziawg-tools kmod-amneziawg luci-app-amneziawg 2>/dev/null && return

    echo -e "${YELLOW}Репозиторий недоступен. Скачивание AmneziaWG с GitHub...${NC}"
    PKGARCH=$($PKG_MANAGER print-architecture 2>/dev/null | awk 'BEGIN {max=0} {if ($3 > max) {max = $3; arch = $2}} END {print arch}')
    TARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 1)
    SUBTARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 2)
    VER=$(ubus call system board | jsonfilter -e '@.release.version')
    POSTFIX="_v${VER}_${PKGARCH}_${TARGET}_${SUBTARGET}.ipk"
    BASE="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v${VER}/"
    TMPD="/tmp/amneziawg"; mkdir -p "$TMPD"

    for pkg in amneziawg-tools kmod-amneziawg luci-app-amneziawg; do
        FILE="${pkg}${POSTFIX}"
        echo -e "${GREEN}Скачивание $FILE...${NC}"
        curl -fsSL --connect-timeout 30 "${BASE}${FILE}" -o "$TMPD/$FILE" || {
            echo -e "${RED}Ошибка скачивания $FILE. Установите вручную.${NC}"; exit 1;
        }
        $PKG_MANAGER install "$TMPD/$FILE" || {
            echo -e "${RED}Ошибка установки $FILE${NC}"; exit 1;
        }
    done
    rm -rf "$TMPD"
    echo -e "${GREEN}AmneziaWG установлен${NC}"
}

setup_dnsmasq() {
    if $PKG_MANAGER list-installed 2>/dev/null | grep -q dnsmasq-full; then
        echo -e "${GREEN}dnsmasq-full уже установлен${NC}"
    else
        echo -e "${GREEN}Замена dnsmasq на dnsmasq-full...${NC}"
        cd /tmp
        $PKG_MANAGER download dnsmasq-full
        $PKG_MANAGER remove dnsmasq
        $PKG_MANAGER install /tmp/dnsmasq-full*.ipk --force-overwrite
        [ -f /etc/config/dhcp-opkg ] && { cp /etc/config/dhcp /etc/config/dhcp-old; mv /etc/config/dhcp-opkg /etc/config/dhcp; }
    fi
    if ! uci get dhcp.@dnsmasq[0].confdir 2>/dev/null | grep -q /tmp/dnsmasq.d; then
        uci set dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d'
        uci commit dhcp
    fi
}

read_awg_params() {
    echo -e "${YELLOW}--- Параметры AmneziaWG 2.0 ---${NC}"
    read -r -p "Приватный ключ [Interface]: " AWG_PRIVATE_KEY
    while true; do
        read -r -p "Внутренний IP с маской (например 10.0.0.2/24) [Interface]: " AWG_IP
        echo "$AWG_IP" | grep -oqE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$' && break
        echo "Неверный IP, повторите"
    done
    read -r -p "Jc (junk packet count) [Interface]: " AWG_JC
    read -r -p "Jmin (junk packet minimum size) [Interface]: " AWG_JMIN
    read -r -p "Jmax (junk packet maximum size) [Interface]: " AWG_JMAX
    read -r -p "S1 (junk packet size1) [Interface]: " AWG_S1
    read -r -p "S2 (junk packet size2) [Interface]: " AWG_S2
    read -r -p "H1 (header packet size1) [Interface]: " AWG_H1
    read -r -p "H2 (header packet size2) [Interface]: " AWG_H2
    read -r -p "H3 (header packet size3) [Interface]: " AWG_H3
    read -r -p "H4 (header packet size4) [Interface]: " AWG_H4
    read -r -p "Публичный ключ [Peer]: " AWG_PUBLIC_KEY
    read -r -p "PresharedKey (или Enter): " AWG_PRESHARED_KEY
    read -r -p "Endpoint хост (без порта) [Peer]: " AWG_ENDPOINT
    read -r -p "Endpoint порт [51820]: " AWG_ENDPOINT_PORT
    AWG_ENDPOINT_PORT=${AWG_ENDPOINT_PORT:-51820}
}

setup_awg0() {
    echo -e "${GREEN}Настройка AmneziaWG 2.0 (awg0) — основной VPN...${NC}"
    read_awg_params

    uci set network.awg0=interface
    uci set network.awg0.proto='amneziawg'
    uci set network.awg0.private_key="$AWG_PRIVATE_KEY"
    uci set network.awg0.addresses="$AWG_IP"
    uci set network.awg0.listen_port='51820'
    uci set network.awg0.awg_jc="$AWG_JC"
    uci set network.awg0.awg_jmin="$AWG_JMIN"
    uci set network.awg0.awg_jmax="$AWG_JMAX"
    uci set network.awg0.awg_s1="$AWG_S1"
    uci set network.awg0.awg_s2="$AWG_S2"
    uci set network.awg0.awg_h1="$AWG_H1"
    uci set network.awg0.awg_h2="$AWG_H2"
    uci set network.awg0.awg_h3="$AWG_H3"
    uci set network.awg0.awg_h4="$AWG_H4"

    uci add network amneziawg_awg0 >/dev/null 2>&1
    uci set network.@amneziawg_awg0[0]=amneziawg_awg0
    uci set network.@amneziawg_awg0[0].name='awg0_client'
    uci set network.@amneziawg_awg0[0].public_key="$AWG_PUBLIC_KEY"
    uci set network.@amneziawg_awg0[0].preshared_key="$AWG_PRESHARED_KEY"
    uci set network.@amneziawg_awg0[0].route_allowed_ips='0'
    uci set network.@amneziawg_awg0[0].persistent_keepalive='25'
    uci set network.@amneziawg_awg0[0].endpoint_host="$AWG_ENDPOINT"
    uci set network.@amneziawg_awg0[0].endpoint_port="$AWG_ENDPOINT_PORT"
    uci set network.@amneziawg_awg0[0].allowed_ips='0.0.0.0/0'
    uci commit network
    echo -e "${GREEN}awg0 создан${NC}"
}

setup_awg1() {
    echo -e "${GREEN}Настройка AmneziaWG 2.0 (awg1) — YouTube/Google...${NC}"
    read -r -p "Использовать те же Amnezia-параметры (Jc/Jmin/Jmax/S1/S2/H1-H4), что и для awg0? (y/n): " SAME
    if [ "$SAME" = "y" ] || [ "$SAME" = "Y" ]; then
        read -r -p "Приватный ключ awg1 [Interface]: " AWG_PRIVATE_KEY
        while true; do
            read -r -p "Внутренний IP с маской awg1 [Interface]: " AWG_IP
            echo "$AWG_IP" | grep -oqE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$' && break
            echo "Неверный IP, повторите"
        done
        read -r -p "Публичный ключ awg1 [Peer]: " AWG_PUBLIC_KEY
        read -r -p "PresharedKey awg1 (или Enter): " AWG_PRESHARED_KEY
        read -r -p "Endpoint хост awg1 [Peer]: " AWG_ENDPOINT
        read -r -p "Endpoint порт awg1 [51820]: " AWG_ENDPOINT_PORT
        AWG_ENDPOINT_PORT=${AWG_ENDPOINT_PORT:-51820}
    else
        read_awg_params
    fi

    uci set network.awg1=interface
    uci set network.awg1.proto='amneziawg'
    uci set network.awg1.private_key="$AWG_PRIVATE_KEY"
    uci set network.awg1.addresses="$AWG_IP"
    uci set network.awg1.listen_port='51821'
    uci set network.awg1.awg_jc="$AWG_JC"
    uci set network.awg1.awg_jmin="$AWG_JMIN"
    uci set network.awg1.awg_jmax="$AWG_JMAX"
    uci set network.awg1.awg_s1="$AWG_S1"
    uci set network.awg1.awg_s2="$AWG_S2"
    uci set network.awg1.awg_h1="$AWG_H1"
    uci set network.awg1.awg_h2="$AWG_H2"
    uci set network.awg1.awg_h3="$AWG_H3"
    uci set network.awg1.awg_h4="$AWG_H4"

    uci add network amneziawg_awg1 >/dev/null 2>&1
    uci set network.@amneziawg_awg1[0]=amneziawg_awg1
    uci set network.@amneziawg_awg1[0].name='awg1_client'
    uci set network.@amneziawg_awg1[0].public_key="$AWG_PUBLIC_KEY"
    uci set network.@amneziawg_awg1[0].preshared_key="$AWG_PRESHARED_KEY"
    uci set network.@amneziawg_awg1[0].route_allowed_ips='0'
    uci set network.@amneziawg_awg1[0].persistent_keepalive='25'
    uci set network.@amneziawg_awg1[0].endpoint_host="$AWG_ENDPOINT"
    uci set network.@amneziawg_awg1[0].endpoint_port="$AWG_ENDPOINT_PORT"
    uci set network.@amneziawg_awg1[0].allowed_ips='0.0.0.0/0'
    uci commit network
    echo -e "${GREEN}awg1 создан${NC}"
}

setup_routing() {
    echo -e "${GREEN}Настройка Policy-Based Routing (ip rule + ip route)...${NC}"

    grep -q "99 vpn" /etc/iproute2/rt_tables || echo '99 vpn' >> /etc/iproute2/rt_tables
    grep -q "110 vpninternal" /etc/iproute2/rt_tables || echo '110 vpninternal' >> /etc/iproute2/rt_tables

    if ! uci show network 2>/dev/null | grep -q mark0x1; then
        uci add network rule
        uci set network.@rule[-1].name='mark0x1'
        uci set network.@rule[-1].mark='0x1'
        uci set network.@rule[-1].priority='100'
        uci set network.@rule[-1].lookup='vpn'
        uci commit network
    fi

    if ! uci show network 2>/dev/null | grep -q mark0x2; then
        uci add network rule
        uci set network.@rule[-1].name='mark0x2'
        uci set network.@rule[-1].mark='0x2'
        uci set network.@rule[-1].priority='110'
        uci set network.@rule[-1].lookup='vpninternal'
        uci commit network
    fi

    if ! uci show network 2>/dev/null | grep -q "vpn_route$"; then
        uci set network.vpn_route=route
        uci set network.vpn_route.name='vpn'
        uci set network.vpn_route.interface='awg0'
        uci set network.vpn_route.table='vpn'
        uci set network.vpn_route.target='0.0.0.0/0'
        uci commit network
    fi

    if ! uci show network 2>/dev/null | grep -q "vpninternal_route$"; then
        uci set network.vpninternal_route=route
        uci set network.vpninternal_route.name='vpninternal'
        uci set network.vpninternal_route.interface='awg1'
        uci set network.vpninternal_route.table='vpninternal'
        uci set network.vpninternal_route.target='0.0.0.0/0'
        uci commit network
    fi
    echo -e "${GREEN}Маршрутизация настроена${NC}"
}

setup_firewall() {
    echo -e "${GREEN}Настройка Firewall zones (fw4)...${NC}"

    for z in awg awg_internal; do
        if ! uci show firewall 2>/dev/null | grep -q "@zone.*name='$z'"; then
            uci add firewall zone
            uci set firewall.@zone[-1].name="$z"
            [ "$z" = "awg" ] && uci set firewall.@zone[-1].network='awg0'
            [ "$z" = "awg_internal" ] && uci set firewall.@zone[-1].network='awg1'
            uci set firewall.@zone[-1].forward='REJECT'
            uci set firewall.@zone[-1].output='ACCEPT'
            uci set firewall.@zone[-1].input='REJECT'
            uci set firewall.@zone[-1].masq='1'
            uci set firewall.@zone[-1].mtu_fix='1'
            uci set firewall.@zone[-1].family='ipv4'
            uci commit firewall
            echo -e "${GREEN}Zone $z создана${NC}"
        else
            echo -e "${GREEN}Zone $z уже существует${NC}"
        fi
    done

    for fwd in awg awg_internal; do
        if ! uci show firewall 2>/dev/null | grep -q "@forwarding.*name='${fwd}-lan'"; then
            uci add firewall forwarding
            uci set firewall.@forwarding[-1].name="${fwd}-lan"
            uci set firewall.@forwarding[-1].src='lan'
            uci set firewall.@forwarding[-1].dest="$fwd"
            uci set firewall.@forwarding[-1].family='ipv4'
            uci commit firewall
            echo -e "${GREEN}Forwarding ${fwd}-lan создан${NC}"
        fi
    done
}

setup_nft() {
    echo -e "${GREEN}Настройка nftables (fw4) + nftsets...${NC}"
    mkdir -p /etc/nftables.d

    cat > /etc/nftables.d/10-vpn-sets.nft << 'EOF'
# AmneziaWG 2.0 nftsets для раздельной маршрутизации
set vpn_domains {
    type ipv4_addr
    flags interval
    auto-merge
    comment "Основной VPN (awg0) — заблокированные ресурсы"
}
set vpn_domains_internal {
    type ipv4_addr
    flags interval
    auto-merge
    comment "Внутренний VPN (awg1) — YouTube/Google"
}
EOF

    cat > /etc/nftables.d/99-vpn-mark.nft << 'EOF'
# Маркировка forwarded трафика из LAN (до routing decision)
add rule inet fw4 mangle_prerouting ip daddr @vpn_domains meta mark set 0x1 counter comment "awg0 main"
add rule inet fw4 mangle_prerouting ip daddr @vpn_domains_internal meta mark set 0x2 counter comment "awg1 yt"

# Маркировка трафика от самого роутера (type route hook — rerouting)
chain route_output {
    type route hook output priority mangle; policy accept;
    ip daddr @vpn_domains meta mark set 0x1 counter comment "awg0 local"
    ip daddr @vpn_domains_internal meta mark set 0x2 counter comment "awg1 local"
}
EOF
    echo -e "${GREEN}nftables rules созданы${NC}"
}

setup_dns_resolver() {
    echo "Настроить DNS-шифрование (Stubby/DoT)?"
    echo "1) Нет (по умолчанию)"
    echo "2) Stubby"
    read -r -p "Ваш выбор: " DNS_CHOICE
    if [ "$DNS_CHOICE" = "2" ]; then
        $PKG_MANAGER install stubby
        uci set dhcp.@dnsmasq[0].noresolv="1"
        uci -q delete dhcp.@dnsmasq[0].server
        uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#5453"
        uci add_list dhcp.@dnsmasq[0].server='/use-application-dns.net/'
        uci commit dhcp
        /etc/init.d/stubby enable
        /etc/init.d/stubby start
        echo -e "${GREEN}Stubby настроен${NC}"
    fi
}

setup_getdomains() {
    echo "Выберите список доменов для основного VPN (awg0):"
    echo "1) Россия inside (вы в РФ, VPN для заблокированных ресурсов)"
    echo "2) Россия outside (вы за пределами РФ, VPN для русских ресурсов)"
    echo "3) Украина"
    echo "4) Пропустить"
    read -r -p "Ваш выбор: " COUNTRY

    case "$COUNTRY" in
        1) DOMAINS_URL="https://raw.githubusercontent.com/Rengos/world/refs/heads/main/inside.lst" ;;
        2) DOMAINS_URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/outside-dnsmasq-nfset.lst" ;;
        3) DOMAINS_URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Ukraine/inside-dnsmasq-nfset.lst" ;;
        4) echo "Пропускаем"; return ;;
        *) echo "Неверный выбор"; exit 1 ;;
    esac

    cat << EOF > /etc/init.d/getdomains
#!/bin/sh /etc/rc.common
START=99
start() {
    mkdir -p /tmp/dnsmasq.d
    local count=0
    while [ \$count -lt 5 ]; do
        if curl -fsSL --connect-timeout 15 "$DOMAINS_URL" -o /tmp/dnsmasq.d/domains.lst; then
            # Удаляем youtube/google из основного списка (чтобы не дублировались)
            sed -i '/youtube\\.com\\|googlevideo\\.com\\|youtubekids\\.com\\|googleapis\\.com\\|ytimg\\.com\\|ggpht\\.com/d' /tmp/dnsmasq.d/domains.lst
            # Добавляем YT/Google во внутренний nftset (awg1)
            cat >> /tmp/dnsmasq.d/domains.lst << 'INNER'
nftset=/youtube.com/4#inet#fw4#vpn_domains_internal
nftset=/googlevideo.com/4#inet#fw4#vpn_domains_internal
nftset=/youtubekids.com/4#inet#fw4#vpn_domains_internal
nftset=/googleapis.com/4#inet#fw4#vpn_domains_internal
nftset=/ytimg.com/4#inet#fw4#vpn_domains_internal
nftset=/ggpht.com/4#inet#fw4#vpn_domains_internal
INNER
            if dnsmasq --conf-file=/tmp/dnsmasq.d/domains.lst --test 2>&1 | grep -q "syntax check OK"; then
                /etc/init.d/dnsmasq restart
                return 0
            fi
        fi
        count=\$((count + 1))
        sleep 5
    done
    logger -t getdomains "Failed to download/update domains list"
}
EOF
    chmod +x /etc/init.d/getdomains
    /etc/init.d/getdomains enable

    if ! crontab -l 2>/dev/null | grep -q /etc/init.d/getdomains; then
        (crontab -l 2>/dev/null; echo "0 */8 * * * /etc/init.d/getdomains start") | crontab -
        /etc/init.d/cron enable 2>/dev/null
        /etc/init.d/cron restart
    fi

    echo -e "${GREEN}Загрузка списка доменов...${NC}"
    /etc/init.d/getdomains start
}

# ========== MAIN ==========
check_repo
install_base
install_awg_packages
setup_dnsmasq
setup_awg0
setup_awg1
setup_routing
setup_firewall
setup_nft
setup_dns_resolver
setup_getdomains

echo -e "${GREEN}Перезапуск сети и firewall...${NC}"
/etc/init.d/network restart
/etc/init.d/firewall restart

echo ""
echo -e "${GREEN}=== Готово! AmneziaWG 2.0 + раздельная маршрутизация настроены ===${NC}"
echo ""
echo "Проверка:"
echo "  nft list set inet fw4 vpn_domains"
echo "  nft list set inet fw4 vpn_domains_internal"
echo "  ip rule show"
echo "  ip route show table vpn"
echo "  ip route show table vpninternal"
echo ""
echo "WAN (L2TP/PPPoE/DHCP) не был изменён."
