# mini-container

Учебная реализация Linux-контейнера "с нуля" на bash + C, используя Namespaces, cgroups v2, seccomp, capabilities, overlayfs, bridge-сеть с NAT.
Цель проекта - разбор того, как контейнеризация устроена изнутри.

## Применённые навыки и технологии
- **Bash-скриптинг** - оркестрация всего процесса, работа с  процессами, cleanup() и тд.
- **C** - написание seccomp, работа с libseccomp 
- **Сетевой стек Linux** - bridge, veth-пары, NAT/MASQUERADE и проброс портов через iptables
- **Linux namespaces** - mount, pid, net, uts, ipc, cgroup через unshare и nsenter`
- **pivot_root** для смены корня 
- **OverlayFS** - copy-on-write система, как в Docker (lower/upper/work/merged)
- **Cgroups** - лимиты памяти, CPU , числа процессов 
- **Seccomp** - фильтр syscalls, написан на C с libseccomp
- **Linux capabilities** - через setpriv 
- **debootstrap** - сборка минимального Debian rootfs

## Запуск

```bash
└─$ bash container.sh 
[info] использую образ в /home/user/pet/container/base_debian
[info] FS mounted at /home/user/pet/container/overlay/merged 
[info] CPID=2055270
[info] сеть готова: контейнер 10.200.1.2/24 -> мост 10.200.1.1/24 -> NAT через wlo1
[info] localhost:80 -> 10.200.1.2:80
root@192:/# 

```

Первый запуск разворачивает Debian через debootstrap, монтирует overlay, компилирует seccomp-loader, поднимает namespaces/сеть/cgroups и заводит в интерактивный bash внутри контейнера. Выход запускает cleanup(), где снимаются  ресурсы хоста

Требования: Linux с cgroups v2, sudo, пакеты debootstrap iptables iproute2 socat util-linux gcc libseccomp-dev

## Конфигурация

В шапке `container.sh`: MEM_LIMIT, CPU_MAX, PID_LIMIT, PORT_FORWARD, сетевые параметры (BRIDGE_IP, CTR_IP, CTR_SUBNET)

## Как это работает

1. debootstrap → rootfs, overlayFS поверх него
2. unshare создаёt namespaces, внутри стартует ns-init.sh (pivot_root, монтирование /proc /sys /dev/pts), процесс висит как `sleep infinity` . Его PID используется для настройки снаружи
3. Снаружи по этому PID настраиваются: cgroup + лимиты, bridge + veth , адрес/маршрут через `nsenter -n`, NAT на хосте
4. socat пробрасывает порты из PORT_FORWARD
5. Вход в контейнер: nsenter во все namespaces + capabilities через setpriv + seccomp-loader → `exec /bin/bash`.


## Можно добавить

- Whitelist seccomp-профиль
- Rootless-режим
- Несколько контейнеров одновременно


