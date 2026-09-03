// ff-test: evdev force-feedback 测试工具 (aarch64-android)
// 用法: ff-test <event节点> [duration_ms] [strong] [weak]
// 例:  ff-test /dev/input/event8 300 0xc000 0xc000
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/input.h>

static int test_bit(int bit, const volatile unsigned long *array) {
    return (array[bit / (8 * sizeof(long))] >> (bit % (8 * sizeof(long)))) & 1;
}

/* 从 /proc/bus/input/devices 找合成设备的 event 节点(避免 WebUI 嵌套 shell) */
static int find_combined(char *out, size_t sz) {
    FILE *f = fopen("/proc/bus/input/devices", "r");
    if (!f) return -1;
    char line[256];
    int in_target = 0;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "N: Name=", 8) == 0)
            in_target = strstr(line, "Combined Joy-Cons") != NULL;
        else if (in_target && strncmp(line, "H: Handlers=", 12) == 0) {
            char *h = strstr(line, "event");
            if (h) {
                char *e = h;
                while (*e && *e != ' ' && *e != '\n' && *e != '\t') e++;
                *e = 0;
                snprintf(out, sz, "/dev/input/%s", h);
                fclose(f);
                return 0;
            }
        }
    }
    fclose(f);
    return -1;
}

int main(int argc, char **argv) {
    char autop[64];
    /* 自动发现:无参数,或第一个参数不是 /dev 路径(WebUI 只传数值参数,
       ksu.exec 环境下无法先解析节点)——此时参数整体前移一位 */
    int argi = 1;
    if (argc < 2 || strncmp(argv[1], "/dev/", 5) != 0) {
        if (find_combined(autop, sizeof(autop)) != 0) {
            fprintf(stderr, "用法: ff-test [event节点] [duration_ms] [strong] [weak]\n"
                            "(自动发现合成设备失败:两只手柄都连了吗?)\n");
            return 1;
        }
        printf("auto: %s\n", autop);
    } else {
        argi = 2;  /* 显式给了节点,数值参数从 argv[2] 起 */
    }
    const char *path = argi == 2 ? argv[1] : autop;
    int duration = argc > argi + 1 ? atoi(argv[argi]) : 300;
    unsigned short strong = argc > argi + 2 ? (unsigned short)strtol(argv[argi+1], NULL, 0) : 0xc000;
    unsigned short weak   = argc > argi + 3 ? (unsigned short)strtol(argv[argi+2], NULL, 0) : 0xc000;

    int fd = open(path, O_RDWR);
    if (fd < 0) { fprintf(stderr, "open %s: %s\n", path, strerror(errno)); return 1; }

    // 确认 FF 能力
    unsigned char ff_bits[(FF_MAX + 7) / 8 + 1] = {0};
    if (ioctl(fd, EVIOCGBIT(EV_FF, sizeof(ff_bits)), ff_bits) < 0) {
        fprintf(stderr, "EVIOCGBIT(EV_FF): %s\n", strerror(errno)); return 1;
    }
    printf("FF_RUMBLE 支持位: %d\n", test_bit(FF_RUMBLE, (unsigned long *)ff_bits));
    printf("FF_PERIODIC 支持位: %d\n", test_bit(FF_PERIODIC, (unsigned long *)ff_bits));

    struct ff_effect effect = {0};
    effect.type = FF_RUMBLE;
    effect.id = -1;                          // 让内核分配 id
    effect.replay.length = duration;
    effect.replay.delay = 0;
    effect.u.rumble.strong_magnitude = strong; // LF 马达
    effect.u.rumble.weak_magnitude = weak;     // HF 马达

    if (ioctl(fd, EVIOCSFF, &effect) == -1) {
        fprintf(stderr, "EVIOCSFF: %s\n", strerror(errno)); return 1;
    }
    printf("effect id=%d 已上传 (len=%dms strong=0x%04x weak=0x%04x)\n",
           effect.id, duration, strong, weak);

    // 播放
    struct input_event play = {0};
    gettimeofday(&play.time, NULL);
    play.type = EV_FF;
    play.code = effect.id;
    play.value = 1;                          // 1 = start
    if (write(fd, &play, sizeof(play)) == -1) {
        fprintf(stderr, "write EV_FF: %s\n", strerror(errno)); return 1;
    }
    printf("已触发,等 %dms\n", duration);
    usleep(duration * 1000 + 200 * 1000);

    // 停止并清除
    play.value = 0;
    gettimeofday(&play.time, NULL);
    write(fd, &play, sizeof(play));
    ioctl(fd, EVIOCRMFF, effect.id);
    printf("完成\n");
    close(fd);
    return 0;
}
