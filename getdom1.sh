#!/bin/sh
# OpenWrt 24.x (fw4/nftables) + AmneziaWG 2.0 (awg0 + awg1)
# GL.iNet GL-MT3000 / mediatek/filogic / aarch64_cortex-a53
# Раздельная маршрутизация через nftsets. WAN не трогается.

GREEN='\033[32;1m'
RED='\033[31;1m'
BLUE='\033[34;1m'
YELLOW='\033[33;1m'
NC='\033[0m'

# FIX 1: /etc/os-release не имеет 'source' в /bin/sh — используем '.'
. /etc/os-release

VERSION_ID=$(echo "$VERSION" | awk -F. '{print $1}')
[ "$VERSION_ID" -ne 24 ] && { printf "${RED}Скрипт только для OpenWrt 24.x (fw4/nftables)${NC}\n"; exit 1; }

MODEL=$(cat /tmp/sysinfo/model 2>/dev/null || echo "Unknown")
printf "${BLUE}Model: $MODEL${NC}\n"
printf "${BLUE}Version: $OPENWRT_RELEASE${NC}\n"
printf "${RED}Все действия нельзя откатить автоматически.${NC}\n"

# AWG 2.0 detection
AWG_VERSION="1.0"
MAJOR_VERSION=$(echo "$VERSION" | cut -d '.' -f 1)
MINOR_VERSION=$(echo "$VERSION" | cut -d '.' -f 2)
PATCH_VERSION=$(echo "$VERSION" | cut -d '.' -f 3)

if [ "$MAJOR_VERSION" -gt 24 ] || \
   [ "$MAJOR_VERSION" -eq 24 ] && [ "$MINOR_VERSION" -gt 10 ] || \
   [ "$MAJOR_VERSION" -eq 24 ] && [ "$MINOR_VERSION" -eq 10 ] && [ "$PATCH_VERSION" -ge 3 ] || \
   [ "$MAJOR_VERSION" -eq 23 ] && [ "$MINOR_VERSION" -eq 5 ] && [ "$PATCH_VERSION" -ge 6 ]; then
    AWG_VERSION="2.0"
    LUCI_PKG="luci-proto-amneziawg"
else
    LUCI_PKG="luci-app-amneziawg"
fi

printf "${BLUE}Detected AmneziaWG version: $AWG_VERSION${NC}\n"
printf "${BLUE}LuCI package: $LUCI_PKG${NC}\n"

PKG_MANAGER="opkg"
command -v apk >/dev/null 2>&1 && PKG_MANAGER="apk"

check_repo() {
    printf "${GREEN}Обновление репозиториев...${NC}\n"
    $PKG_MANAGER update || { printf "${RED}Нет доступа к репозиториям${NC}\n"; exit 1; }
}

install_base() {
    for pkg in curl nano; do
        if $PKG_MANAGER list-installed 2>/dev/null | grep -q "^$pkg "; then
            printf "${GREEN}$pkg уже установлен${NC}\n"
        else
            printf "${GREEN}Установка $pkg...${NC}\n"
            $PKG_MANAGER install "$pkg"
        fi
    done
}

install_awg_packages() {
    if $PKG_MANAGER list-installed 2>/dev/null | grep -q amneziawg-tools && \
       $PKG_MANAGER list-installed 2>/dev/null | grep -q kmod-amneziawg && \
       $PKG_MANAGER list-installed 2>/dev/null | grep -q "$LUCI_PKG"; then
        printf "${GREEN}AmneziaWG $AWG_VERSION уже установлен${NC}\n"
        return
    fi

    printf "${GREEN}Попытка установить AmneziaWG $AWG_VERSION из репозитория...${NC}\n"
    $PKG_MANAGER install amneziawg-tools kmod-amneziawg "$LUCI_PKG" 2>/dev/null && return

    printf "${YELLOW}Репозиторий недоступен. Скачивание AmneziaWG с GitHub...${NC}\n"
    PKGARCH=$($PKG_MANAGER print-architecture 2>/dev/null | awk 'BEGIN {max=0} {if ($3 > max) {max = $3; arch = $2}} END {print arch}')
    TARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 1)
    SUBTARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 2)
    VER=$(ubus call system board | jsonfilter -e '@.release.version')
    POSTFIX="_v${VER}_${PKGARCH}_${TARGET}_${SUBTARGET}.ipk"
    BASE="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v${VER}/"
    TMPD="/tmp/amneziawg"; mkdir -p "$TMPD"

    for pkg in kmod-amneziawg amneziawg-tools "$LUCI_PKG"; do
        FILE="${pkg}${POSTFIX}"
        printf "${GREEN}Скачивание $FILE...${NC}\n"
        curl -fsSL --connect-timeout 30 "${BASE}${FILE}" -o "$TMPD/$FILE" || {
            printf "${RED}Ошибка скачивания $FILE${NC}\n"
            printf "${YELLOW}Проверьте, что релиз v${VER} существует на GitHub Slava-Shchipunov/awg-openwrt${NC}\n"
            exit 1
        }
        $PKG_MANAGER install "$TMPD/$FILE" || {
            printf "${RED}Ошибка установки $FILE${NC}\n"; exit 1
        }
    done

    # AWG 2.0 русская локализация (опционально)
    if [ "$AWG_VERSION" = "2.0" ]; then
        RU_FILE="luci-i18n-amneziawg-ru${POSTFIX}"
        if curl -fsSL --connect-timeout 15 "${BASE}${RU_FILE}" -o "$TMPD/$RU_FILE" 2>/dev/null; then
            $PKG_MANAGER install "$TMPD/$RU_FILE" 2>/dev/null && printf "${GREEN}Русская локализация установлена${NC}\n"
        fi
    fi

    rm -rf "$TMPD"
    printf "${GREEN}AmneziaWG $AWG_VERSION установлен${NC}\n"
}

setup_dnsmasq() {
    if $PKG_MANAGER list-installed 2>/dev/null | grep -q dnsmasq-full; then
        printf "${GREEN}dnsmasq-full уже установлен${NC}\n"
    else
        printf "${GREEN}Замена dnsmasq на dnsmasq-full...${NC}\n"
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
    printf "${YELLOW}--- Параметры AmneziaWG $AWG_VERSION ---${NC}\n"
    read -r AWG_PRIVATE_KEY && printf "Приватный ключ [Interface]: " || { printf "Приватный ключ [Interface]: "; read -r AWG_PRIVATE_KEY; }
    # FIX 2: read -r -p не поддерживается в /bin/sh — используем printf + read
    printf "Приватный ключ [Interface]: "; read -r AWG_PRIVATE_KEY
    while true; do
        printf "Внутренний IP с маской (например 10.0.0.2/24) [Interface]: "; read -r AWG_IP
        echo "$AWG_IP" | grep -oqE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$' && break
        echo "Неверный IP, повторите"
    done
    printf "Jc (junk packet count) [Interface]: "; read -r AWG_JC
    printf "Jmin (junk packet minimum size) [Interface]: "; read -r AWG_JMIN
    printf "Jmax (junk packet maximum size) [Interface]: "; read -r AWG_JMAX
    printf "S1 (junk packet size1) [Interface]: "; read -r AWG_S1
    printf "S2 (junk packet size2) [Interface]: "; read -r AWG_S2
    printf "H1 (header packet size1) [Interface]: "; read -r AWG_H1
    printf "H2 (header packet size2) [Interface]: "; read -r AWG_H2
    printf "H3 (header packet size3) [Interface]: "; read -r AWG_H3
    printf "H4 (header packet size4) [Interface]: "; read -r AWG_H4

    if [ "$AWG_VERSION" = "2.0" ]; then
        printf "${YELLOW}--- Дополнительные параметры AmneziaWG 2.0 (опционально, Enter чтобы пропустить) ---${NC}\n"
        printf "S3 [Interface]: "; read -r AWG_S3
        printf "S4 [Interface]: "; read -r AWG_S4
        printf "I1 [Interface]: "; read -r AWG_I1
        printf "I2 [Interface]: "; read -r AWG_I2
        printf "I3 [Interface]: "; read -r AWG_I3
        printf "I4 [Interface]: "; read -r AWG_I4
        printf "I5 [Interface]: "; read -r AWG_I5
    fi

    printf "Публичный ключ [Peer]: "; read -r AWG_PUBLIC_KEY
    printf "PresharedKey (или Enter): "; read -r AWG_PRESHARED_KEY
    printf "Endpoint хост (без порта) [Peer]: "; read -r AWG_ENDPOINT
    printf "Endpoint порт [51820]: "; read -r AWG_ENDPOINT_PORT
    AWG_ENDPOINT_PORT=${AWG_ENDPOINT_PORT:-51820}
}

apply_awg_params() {
    local iface="$1"
    uci set network.${iface}.proto='amneziawg'
    uci set network.${iface}.private_key="$AWG_PRIVATE_KEY"
    uci set network.${iface}.addresses="$AWG_IP"
    uci set network.${iface}.awg_jc="$AWG_JC"
    uci set network.${iface}.awg_jmin="$AWG_JMIN"
    uci set network.${iface}.awg_jmax="$AWG_JMAX"
    uci set network.${iface}.awg_s1="$AWG_S1"
    uci set network.${iface}.awg_s2="$AWG_S2"
    uci set network.${iface}.awg_h1="$AWG_H1"
    uci set network.${iface}.awg_h2="$AWG_H2"
    uci set network.${iface}.awg_h3="$AWG_H3"
    uci set network.${iface}.awg_h4="$AWG_H4"

    if [ "$AWG_VERSION" = "2.0" ]; then
        [ -n "$AWG_S3" ] && uci set network.${iface}.awg_s3="$AWG_S3"
        [ -n "$AWG_S4" ] && uci set network.${iface}.awg_s4="$AWG_S4"
        [ -n "$AWG_I1" ] && uci set network.${iface}.awg_i1="$AWG_I1"
        [ -n "$AWG_I2" ] && uci set network.${iface}.awg_i2="$AWG_I2"
        [ -n "$AWG_I3" ] && uci set network.${iface}.awg_i3="$AWG_I3"
        [ -n "$AWG_I4" ] && uci set network.${iface}.awg_i4="$AWG_I4"
        [ -n "$AWG_I5" ] && uci set network.${iface}.awg_i5="$AWG_I5"
    fi
}

setup_awg0() {
    printf "${GREEN}Настройка AmneziaWG $AWG_VERSION (awg0) — основной VPN...${NC}\n"
    read_awg_params

    uci set network.awg0=interface
    apply_awg_params "awg0"
    uci set network.awg0.listen_port='51820'

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
    printf "${GREEN}awg0 создан${NC}\n"
}

setup_awg1() {
    printf "${GREEN}Настройка AmneziaWG $AWG_VERSION (awg1) — YouTube/Google...${NC}\n"

    # FIX 3: сломанный read с echo -n внутри — разбито на отдельные printf
    printf "Использовать те же Amnezia-параметры (Jc/Jmin/Jmax/S1/S2/H1-H4"
    [ "$AWG_VERSION" = "2.0" ] && printf "/S3/S4/I1-I5"
    printf "), что и для awg0? (y/n): "
    read -r SAME

    if [ "$SAME" = "y" ] || [ "$SAME" = "Y" ]; then
        printf "Приватный ключ awg1 [Interface]: "; read -r AWG_PRIVATE_KEY
        while true; do
            printf "Внутренний IP с маской awg1 [Interface]: "; read -r AWG_IP
            echo "$AWG_IP" | grep -oqE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$' && break
            echo "Неверный IP, повторите"
        done
        printf "Публичный ключ awg1 [Peer]: "; read -r AWG_PUBLIC_KEY
        printf "PresharedKey awg1 (или Enter): "; read -r AWG_PRESHARED_KEY
        printf "Endpoint хост awg1 [Peer]: "; read -r AWG_ENDPOINT
        printf "Endpoint порт awg1 [51820]: "; read -r AWG_ENDPOINT_PORT
        AWG_ENDPOINT_PORT=${AWG_ENDPOINT_PORT:-51820}
    else
        read_awg_params
    fi

    uci set network.awg1=interface
    apply_awg_params "awg1"
    uci set network.awg1.listen_port='51821'

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
    printf "${GREEN}awg1 создан${NC}\n"
}

setup_routing() {
    printf "${GREEN}Настройка Policy-Based Routing (ip rule + ip route)...${NC}\n"

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
    printf "${GREEN}Маршрутизация настроена${NC}\n"
}

setup_firewall() {
    printf "${GREEN}Настройка Firewall zones (fw4)...${NC}\n"

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
            printf "${GREEN}Zone $z создана${NC}\n"
        else
            printf "${GREEN}Zone $z уже существует${NC}\n"
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
            printf "${GREEN}Forwarding ${fwd}-lan создан${NC}\n"
        fi
    done
}

setup_nft() {
    printf "${GREEN}Настройка nftables (fw4) + nftsets...${NC}\n"
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
    printf "${GREEN}nftables rules созданы${NC}\n"
}

setup_dns_resolver() {
    echo "Настроить DNS-шифрование (Stubby/DoT)?"
    echo "1) Нет (по умолчанию)"
    echo "2) Stubby"
    printf "Ваш выбор: "; read -r DNS_CHOICE
    if [ "$DNS_CHOICE" = "2" ]; then
        $PKG_MANAGER install stubby
        uci set dhcp.@dnsmasq[0].noresolv="1"
        uci -q delete dhcp.@dnsmasq[0].server
        uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#5453"
        uci add_list dhcp.@dnsmasq[0].server='/use-application-dns.net/'
        uci commit dhcp
        /etc/init.d/stubby enable
        /etc/init.d/stubby start
        printf "${GREEN}Stubby настроен${NC}\n"
    fi
}

setup_getdomains() {
    echo "Выберите список доменов для основного VPN (awg0):"
    echo "1) Россия inside (вы в РФ, VPN для заблокированных ресурсов)"
    echo "2) Россия outside (вы за пределами РФ, VPN для русских ресурсов)"
    echo "3) Украина"
    echo "4) Пропустить"
    printf "Ваш выбор: "; read -r COUNTRY

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
            sed -i '/youtube\\.com\\|googlevideo\\.com\\|youtubekids\\.com\\|googleapis\\.com\\|ytimg\\.com\\|ggpht\\.com/d' /tmp/dnsmasq.d/domains.lst
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

    printf "${GREEN}Загрузка списка доменов...${NC}\n"
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

printf "${GREEN}Перезапуск сети и firewall...${NC}\n"
/etc/init.d/network restart
/etc/init.d/firewall restart

echo ""
printf "${GREEN}=== Готово! AmneziaWG $AWG_VERSION + раздельная маршрутизация настроены ===${NC}\n"
echo ""
echo "Проверка:"
echo "  nft list set inet fw4 vpn_domains"
echo "  nft list set inet fw4 vpn_domains_internal"
echo "  ip rule show"
echo "  ip route show table vpn"
echo "  ip route show table vpninternal"
echo ""
echo "WAN (L2TP/PPPoE/DHCP) не был изменён."
