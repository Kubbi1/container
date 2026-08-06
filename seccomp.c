#include <seccomp.h>
#include <unistd.h>
#include <stdio.h>

int main(int argc, char **argv)
{
    // Должна быть передана команда для запуска ./seccomp-loader /bin/bash
    if (argc < 2)
        return 1;

    // По умолчанию ВСЕ системные вызовы разрешены.
    scmp_filter_ctx ctx = seccomp_init(SCMP_ACT_ALLOW);

    if (!ctx)
        return 1;

    // Запрещаем трассировку других процессов.
    seccomp_rule_add(ctx,SCMP_ACT_KILL_PROCESS,SCMP_SYS(ptrace),0);

    // Запрещаем работу с keyring ядра.
    seccomp_rule_add(ctx,SCMP_ACT_KILL_PROCESS,SCMP_SYS(keyctl),0);

    // Запрещаем создание ключей ядра.
    seccomp_rule_add(ctx,SCMP_ACT_KILL_PROCESS,SCMP_SYS(add_key),0);

    // Запрещаем получение ключей ядра.
    seccomp_rule_add(ctx,SCMP_ACT_KILL_PROCESS,SCMP_SYS(request_key),0);

    // Запрещаем загрузку нового ядра через kexec.
    seccomp_rule_add(ctx,SCMP_ACT_KILL_PROCESS,SCMP_SYS(kexec_load),0);

    // Запрещаем загрузку eBPF-программ.
    seccomp_rule_add(ctx,SCMP_ACT_KILL_PROCESS,SCMP_SYS(bpf),0);

    // Загружаем фильтр в ядро.
    if (seccomp_load(ctx) != 0)
        return 1;

    // Запускаем указанную программу, под seccomp фильтрами.
    execvp(argv[1], &argv[1]);
    perror("execvp");

    return 1;
}
