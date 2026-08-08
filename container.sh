#!/bin/bash
# ============================================================================
#todo:
#
#проброс портов
#Seccomp - фильтрации системных вызовов
#Cgroups v2 - ограничений по CPU, памяти, диску
#Capabilities - тонкой настройки прав root внутри контейнера
# ============================================================================
set -e
# ----------------------------------------------------------------------------
# ------------------------------CONFIG----------------------------------------
# ----------------------------------------------------------------------------
# CGROUPS
MEM_LIMIT=$((512*1024*1024))
CPU_MAX="50000 100000"
PID_LIMIT=128
# PORT FORWARDING
PORT_FORWARD=(
#    "80"
#    "1337"
#    "22"
)
# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
BASE_DIR="./base_debian"
OVERLAY_DIR="./overlay"
BRIDGE_NAME="clbr0"
BRIDGE_IP="10.200.1.1/24"
CTR_SUBNET="10.200.1.0/24"
CTR_IP="10.200.1.2/24"
CTR_ADDR="${CTR_IP%/*}"
CTR_GW="10.200.1.1"
VETH_HOST="veth-host0"
VETH_CTR="veth-ctr0"

# ----------------------------------------------------------------------------
# Базовый Debian (debootstrap)
# ----------------------------------------------------------------------------
if [ -d "$BASE_DIR/bin" ]; then
    echo "[info] использую образ в $(realpath -e "./base_debian")"
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
# mount OverlayFS
# ----------------------------------------------------------------------------
mkdir -p "$(realpath -m "$OVERLAY_DIR")"/{upper,work,merged}
MERGED="$(realpath -e "$OVERLAY_DIR/merged")"

sudo mount -t overlay overlay \
    -o lowerdir="$(realpath -e "$BASE_DIR")",upperdir="$(realpath -e "$OVERLAY_DIR/upper")",workdir="$(realpath -e "$OVERLAY_DIR/work")" \
    "$MERGED"

# ----------------------------------------------------------------------------
# Seccomp - компилируем скрипт для фильтрации системных вызовов
# ----------------------------------------------------------------------------
if ! dpkg -s libseccomp-dev >/dev/null 2>&1; then
    echo "[info] Installing libseccomp-dev..."
    sudo apt update
    sudo apt install -y libseccomp-dev
fi
gcc seccomp.c -lseccomp -o seccomp-loader
cp seccomp-loader "$MERGED/usr/local/bin/"
chmod +x "$MERGED/usr/local/bin/seccomp-loader"
# ----------------------------------------------------------------------------
# cleanup
# ----------------------------------------------------------------------------
CPID=""
cleanup() {
    echo "[info] очистка..."
    trap - EXIT

    for PID in "${SOCAT_PIDS[@]}"; do
        kill "$PID" 2>/dev/null || true
    done

sudo iptables -D FORWARD -i "$BRIDGE_NAME" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    if [ -n "$CPID" ] && kill -0 "$CPID" 2>/dev/null; then
        # убиваем всех потомков
        pkill -TERM -P "$CPID" 2>/dev/null || true
        sleep 0.2
        pkill -KILL -P "$CPID" 2>/dev/null || true
        sleep 0.1
        kill -TERM "$CPID" 2>/dev/null || true

        wait "$CPID" 2>/dev/null || true
    fi

    EGRESS_IF="$(ip -o route get 1.1.1.1 | grep -oP 'dev \K\S+' || true)"

    if [ -n "$EGRESS_IF" ]; then
        sudo iptables -t nat -D POSTROUTING -s "$CTR_SUBNET" -o "$EGRESS_IF" -j MASQUERADE 2>/dev/null || true
        sudo iptables -D FORWARD -i "$BRIDGE_NAME" -o "$EGRESS_IF" -j ACCEPT 2>/dev/null || true
        sudo iptables -D FORWARD -i "$EGRESS_IF" -o "$BRIDGE_NAME" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    fi

    sudo ip link del "$VETH_HOST" 2>/dev/null || true
    sudo ip link del "$BRIDGE_NAME" 2>/dev/null || true
    sudo rmdir "/sys/fs/cgroup/container-demo" 2>/dev/null || true
    mountpoint -q "$MERGED" && sudo umount -l "$MERGED" || true
}
trap cleanup EXIT
# ----------------------------------------------------------------------------
# копируем Init-script
# ----------------------------------------------------------------------------
NS_INIT="$OVERLAY_DIR/ns-init.sh"
python3 -c "open('$NS_INIT','w').write(open('ns-init.sh','r').read().replace('MERGED_PATH',str('$MERGED')));"
chmod +x "$NS_INIT"
# ----------------------------------------------------------------------------
# Запускаем namespaces фоновым процессом-заглушкой (sleep infinity),
#    чтобы иметь PID для настройки сети снаружи ДО входа в контейнер.
# ----------------------------------------------------------------------------

unshare \
    --mount --cgroup --net --uts --ipc \
    --fork --pid --user --map-root-user  \
    -- "$NS_INIT" &
PID=$!
sleep 0.2
CPID=$(pstree -lp $PID | grep -oP 'sleep\(\K[0-9]+')
echo "[info] CPID=$CPID"
sleep 0.1
# ----------------------------------------------------------------------------
# Cgroups
# ----------------------------------------------------------------------------

CG="/sys/fs/cgroup/container-demo"
sudo mkdir -p "$CG"
sudo bash -c "echo $MEM_LIMIT > $CG/memory.max"
sudo bash -c "echo '$CPU_MAX' > $CG/cpu.max"
sudo bash -c "echo $PID_LIMIT > $CG/pids.max"
sudo bash -c "echo $CPID > $CG/cgroup.procs"


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
#---------------------------------------------------------------------
# PORT FORWARDING на localhost
# ---------------------------------------------------------------------
# localhost -> container port forwarding

#---------------------------------------------------------------------
# PORT FORWARDING localhost -> container
#---------------------------------------------------------------------

SOCAT_PIDS=()

for PORT in "${PORT_FORWARD[@]}"; do

    sudo socat TCP-LISTEN:"$PORT",bind=127.0.0.1,reuseaddr,fork TCP:"$CTR_ADDR":"$PORT" &

    SOCAT_PIDS+=($!)

    echo "[info] localhost:$PORT -> $CTR_ADDR:$PORT"

done

#---------------------------------------------------------------------
# Заходим в контейнер интерактивным bash (те же namespaces + chroot)
# --------------------------------------------------------------------
sudo nsenter -m -u -i -n -p -t "$CPID" -- \
    setpriv \
        --reuid=0 --regid=0 --clear-groups \
        --bounding-set=-all,+chown,+dac_override,+fowner,+setuid,+setgid,+net_bind_service \
        --no-new-privs \
        --inh-caps=-all \
        -- env -i \
            HOME=/root \
            USER=root \
            LOGNAME=root \
            PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
            /usr/local/bin/seccomp-loader /bin/bash
