# mini-container

Учебная реализация Linux-контейнера "с нуля" на bash + C, используя Namespaces, cgroups v2, seccomp, capabilities, overlayfs, bridge-сеть с NAT.
Цель проекта - разбор того, как контейнеризация устроена изнутри.

## Применённые навыки и технологии
- **Bash-скриптинг** - оркестрация всего процесса,  cleanup,
- **C** - написание seccomp, работа с libseccomp
- **Сетевой стек Linux** - bridge, veth-пары, NAT/MASQUERADE и forwarding через iptables
- **Linux namespaces** - mount, pid, net, uts, ipc, cgroup через `unshare`/`nsenter`
- **pivot_root** для смены корня (вместо `chroot`), приватный mount propagation
- **OverlayFS** - CoW-корень (lower/upper/work/merged)
- **Cgroups** - лимиты памяти, CPU (`cpu.max`), числа процессов (`pids.max`)
- **Seccomp** - фильтр syscalls, написан на C с libseccomp, компилируется в отдельный loader-бинарь
- **Linux capabilities** - дроп через `setpriv --bounding-set`, `--no-new-privs`
- **Сетевой стек Linux** - bridge, veth-пары, NAT/MASQUERADE и forwarding через iptables
- **debootstrap** - сборка минимального Debian rootfs

## Быстрый старт

```bash
bash container.sh
```

Первый запуск разворачивает Debian через debootstrap, монтирует overlay, компилирует seccomp-loader, поднимает namespaces/сеть/cgroups и заводит в интерактивный bash внутри контейнера. Выход запускает `cleanup()`, где снимаются все ресурсы хоста.

Требования: Linux с cgroups v2, sudo, пакеты debootstrap iptables iproute2 socat util-linux gcc libseccomp-dev

## Конфигурация

В шапке `run.sh`: MEM_LIMIT, CPU_MAX, PID_LIMIT, PORT_FORWARD, сетевые параметры (BRIDGE_IP, CTR_IP, CTR_SUBNET)

## Как это работает

1. `debootstrap` → rootfs, overlayfs поверх него.
2. `unshare` создаёt namespaces, внутри стартует `ns-init.sh` (`pivot_root`, монтирование `/proc /sys /dev/pts`), процесс висит как `sleep infinity` - стабильный PID для настройки снаружи.
3. Снаружи по этому PID: cgroup + лимиты, bridge + veth в netns контейнера, адрес/маршрут через `nsenter -n`, NAT на хосте.
4. `socat` пробрасывает порты из `PORT_FORWARD`.
5. Вход в контейнер: `nsenter` во все namespaces + `setpriv` (capabilities, no-new-privs) + `seccomp-loader` → `exec /bin/bash`.


## Можно добавить

- Whitelist seccomp-профиль
- Rootless-режим
- Несколько контейнеров одновременно

## Дисклеймер

Образовательный проект. Не для запуска недоверенного кода в продакшене - уровень изоляции ниже, чем у Docker/Podman/gVisor.
