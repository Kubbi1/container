#!/bin/bash
# ============================================================================
# Rootless-контейнер (debootstrap + overlayfs + unshare) с сетью:
#   veth <-> bridge (host) <-> NAT (iptables MASQUERADE) <-> внешний мир
#
# Топология:
#   [eth0 в контейнере] 10.200.1.2/24
#            |
#         veth-ctr0 <---> veth-host0
#                              |
#                          clbr0 (bridge) 10.200.1.1/24  (хост)
#                              |
#                       iptables MASQUERADE -> внешний интерфейс хоста
#todo:
#
#проброс портов
#Seccomp - фильтрации системных вызовов
#Cgroups v2 - ограничений по CPU, памяти, диску
#Capabilities - тонкой настройки прав root внутри контейнера
# ============================================================================
set -e

BASE_DIR="./base_debian"
OVERLAY_DIR="./overlay"

BRIDGE_NAME="clbr0"
BRIDGE_IP="10.200.1.1/24"
CTR_SUBNET="10.200.1.0/24"
CTR_IP="10.200.1.2/24"
CTR_GW="10.200.1.1"
VETH_HOST="veth-host0"
VETH_CTR="veth-ctr0"

# ----------------------------------------------------------------------------
# 1. Базовый Debian (debootstrap)
# ----------------------------------------------------------------------------
if [ -d "$BASE_DIR/bin" ]; then
    echo "[info] base_debian уже существует. Удалите base_debian в случае обновления/поломки образа"
else
    sudo debootstrap --arch=amd64 bookworm "$BASE_DIR" http://deb.debian.org/debian
fi
sudo chown -R "$USER:$USER" "$BASE_DIR"

# DNS внутри контейнера (debootstrap resolv.conf не кладёт)
mkdir -p "$BASE_DIR/etc"
cat > "$BASE_DIR/etc/resolv.conf" <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

# ----------------------------------------------------------------------------
# 2. OverlayFS
# ----------------------------------------------------------------------------
mkdir -p "$(realpath -m "$OVERLAY_DIR")"/{upper,work,merged}
MERGED="$(realpath -e "$OVERLAY_DIR/merged")"

sudo mount -t overlay overlay \
    -o lowerdir="$(realpath -e "$BASE_DIR")",upperdir="$(realpath -e "$OVERLAY_DIR/upper")",workdir="$(realpath -e "$OVERLAY_DIR/work")" \
    "$MERGED"

# ----------------------------------------------------------------------------
# 3 cleanup
# ----------------------------------------------------------------------------
CPID=""
cleanup() {
    echo "[info] очистка сети и окружения..."

    # убиваем "заглушку" (sleep infinity), которая держит namespaces
    if [ -n "$CPID" ] && kill -0 "$CPID" 2>/dev/null; then
        sudo kill -9 "$CPID" 2>/dev/null || true
    fi

    # снимаем iptables-правила
    EGRESS_IF="$(ip -o route get 1.1.1.1 | grep -oP 'dev \K\S+')"
    if [ -n "$EGRESS_IF" ]; then
        sudo iptables -t nat -D POSTROUTING -s "$CTR_SUBNET" -o "$EGRESS_IF" -j MASQUERADE 2>/dev/null || true
        sudo iptables -D FORWARD -i "$BRIDGE_NAME" -o "$EGRESS_IF" -j ACCEPT 2>/dev/null || true
        sudo iptables -D FORWARD -i "$EGRESS_IF" -o "$BRIDGE_NAME" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    fi

    sudo ip link del "$VETH_HOST" 2>/dev/null || true
    sudo ip link del "$BRIDGE_NAME" 2>/dev/null || true

    sudo umount "$MERGED" 2>/dev/null || true
}
trap cleanup EXIT

# ----------------------------------------------------------------------------
# Запускаем namespaces фоновым процессом-заглушкой (sleep infinity),
#    чтобы иметь PID для настройки сети снаружи ДО входа в контейнер.
# ----------------------------------------------------------------------------
unshare \
    --mount --pid --cgroup --net --uts --ipc \
    --fork --user --map-root-user --mount-proc \
    --root "$MERGED" --wd / \
    /bin/sleep infinity &
CPID=$!

# ждём появления netns у процесса
for i in $(seq 1 50); do
    [ -e "/proc/$CPID/ns/net" ] && break
    sleep 0.1
done

# ----------------------------------------------------------------------------
# Bridge на хосте
# ----------------------------------------------------------------------------
if ! ip link show "$BRIDGE_NAME" &>/dev/null; then
    sudo ip link add name "$BRIDGE_NAME" type bridge
    sudo ip addr add "$BRIDGE_IP" dev "$BRIDGE_NAME"
    sudo ip link set "$BRIDGE_NAME" up
fi

# ----------------------------------------------------------------------------
# veth-пара: один конец в bridge, другой - в netns контейнера
# ----------------------------------------------------------------------------
sudo ip link del "$VETH_HOST" 2>/dev/null || true   # на случай мусора от прошлого запуска

sudo ip link add "$VETH_HOST" type veth peer name "$VETH_CTR"
sudo ip link set "$VETH_HOST" master "$BRIDGE_NAME"
sudo ip link set "$VETH_HOST" up

sudo ip link set "$VETH_CTR" netns "$CPID"

# ----------------------------------------------------------------------------
# Настройка сети внутри контейнера (через nsenter в его net-namespace)
# ----------------------------------------------------------------------------
sudo nsenter -t "$CPID" -n -- ip link set "$VETH_CTR" name eth0
sudo nsenter -t "$CPID" -n -- ip addr add "$CTR_IP" dev eth0
sudo nsenter -t "$CPID" -n -- ip link set eth0 up
sudo nsenter -t "$CPID" -n -- ip link set lo up
sudo nsenter -t "$CPID" -n -- ip route add default via "$CTR_GW"

# ----------------------------------------------------------------------------
# NAT + форвардинг на хосте
# ----------------------------------------------------------------------------
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null

EGRESS_IF="$(ip -o route get 1.1.1.1 | grep -oP 'dev \K\S+')" # интерфейс с интернетом
if [ -z "$EGRESS_IF" ]; then
    echo "[warn] не удалось определить внешний интерфейс хоста, NAT может не работать"
fi

sudo iptables -t nat -C POSTROUTING -s "$CTR_SUBNET" -o "$EGRESS_IF" -j MASQUERADE 2>/dev/null || \
sudo iptables -t nat -A POSTROUTING -s "$CTR_SUBNET" -o "$EGRESS_IF" -j MASQUERADE

sudo iptables -C FORWARD -i "$BRIDGE_NAME" -o "$EGRESS_IF" -j ACCEPT 2>/dev/null || \
sudo iptables -A FORWARD -i "$BRIDGE_NAME" -o "$EGRESS_IF" -j ACCEPT

sudo iptables -C FORWARD -i "$EGRESS_IF" -o "$BRIDGE_NAME" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
sudo iptables -A FORWARD -i "$EGRESS_IF" -o "$BRIDGE_NAME" -m state --state RELATED,ESTABLISHED -j ACCEPT

echo "[info] сеть готова: контейнер ${CTR_IP} -> мост ${BRIDGE_IP} -> NAT через ${EGRESS_IF}"

# ----------------------------------------------------------------------------
# Заходим в контейнер интерактивным bash (те же namespaces + chroot)
# ----------------------------------------------------------------------------
sudo nsenter -m -u -i -n -p  -t "$CPID" -- env \
    HOME=/root \
    USER=root \
    LOGNAME=root \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    /bin/bash
