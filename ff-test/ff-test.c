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

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "用法: ff-test <event节点> [duration_ms] [strong_hex] [weak_hex]\n");
        return 1;
    }
    const char *path = argv[1];
    int duration = argc > 2 ? atoi(argv[2]) : 300;
    unsigned short strong = argc > 3 ? (unsigned short)strtol(argv[3], NULL, 0) : 0xc000;
    unsigned short weak   = argc > 4 ? (unsigned short)strtol(argv[4], NULL, 0) : 0xc000;

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
