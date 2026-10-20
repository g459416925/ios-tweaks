// xnotify —— 在设备上发一条 Darwin 通知（设备没有 notifyutil）
#include <stdio.h>
#include <notify.h>

int main(int argc, char *argv[])
{
    if (argc < 2) {
        fprintf(stderr, "usage: xnotify <notification-name>\n");
        return 2;
    }
    uint32_t st = notify_post(argv[1]);
    fprintf(stderr, "notify_post(%s) -> %u\n", argv[1], st);
    return st == 0 ? 0 : 1;
}
