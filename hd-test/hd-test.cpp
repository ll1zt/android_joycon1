// hd-test: Joy-Con HD Rumble 波形播放器 (hidraw 0x10 流式,60Hz)
// 用法: hd-test [hidrawL hidrawR]   不给参数则自动扫 sysfs 找 Joy-Con (L)/(R)
// 波形内置,循环播放,共 4 段,每段之间停 900ms
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <math.h>
#include <signal.h>

// ---- 协议编码 ----
#define HF_AMP_OFF 0x01
#define HF_AMP_MAX 0xC8
#define LF_AMP_OFF 0x40
#define LF_AMP_MAX 0x72

static unsigned char pkt = 0;

struct band {
    unsigned char hf_freq, hf_amp, lf_freq, lf_amp;
};

static void encode(unsigned char *out4, const struct band &b)
{
    out4[0] = b.hf_freq; out4[1] = b.hf_amp;
    out4[2] = b.lf_freq; out4[3] = b.lf_amp;
}

// 向单只手柄写一帧(自己 4 字节 + 对方位置 neutral)
static void write_frame(int fd, const struct band &b, bool is_left)
{
    static const unsigned char NEUTRAL[4] = {0x00, 0x01, 0x40, 0x40};
    unsigned char buf[0x40];
    memset(buf, 0, sizeof(buf));
    buf[0] = 0x10;
    buf[1] = pkt++ & 0x0F;
    if (is_left) { encode(buf+2, b); memcpy(buf+6, NEUTRAL, 4); }
    else         { memcpy(buf+2, NEUTRAL, 4); encode(buf+6, b); }
    if (write(fd, buf, sizeof(buf)) < 0)
        fprintf(stderr, "write: %s\n", strerror(errno));
}

static void send_both(int fdl, int fdr, const struct band &b)
{
    if (fdl >= 0) write_frame(fdl, b, true);
    if (fdr >= 0) write_frame(fdr, b, false);
}

static void stop_both(int fdl, int fdr)
{
    struct band off = {0x00, 0x01, 0x40, 0x40};
    send_both(fdl, fdr, off);
}

static unsigned long now_ms()
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000UL + ts.tv_nsec / 1000000UL;
}

// HF 幅度 0.0-1.0 -> byte
static inline unsigned char hf_amp(float v)
{
    if (v <= 0) return HF_AMP_OFF;
    if (v > 1) v = 1;
    return (unsigned char)(HF_AMP_OFF + v * (HF_AMP_MAX - HF_AMP_OFF));
}
// LF 幅度 0.0-1.0 -> byte (0x40=0.0, 0x72=1.0)
static inline unsigned char lf_amp(float v)
{
    if (v <= 0) return LF_AMP_OFF;
    if (v > 1) v = 1;
    return (unsigned char)(LF_AMP_OFF + v * (LF_AMP_MAX - LF_AMP_OFF));
}

static int g_fdl = -1, g_fdr = -1;
static void on_term(int sig)
{
    (void)sig;
    if (g_fdl >= 0 || g_fdr >= 0) {
        struct band off = {0x00, 0x01, 0x40, 0x40};
        if (g_fdl >= 0) write_frame(g_fdl, off, true);
        if (g_fdr >= 0) write_frame(g_fdr, off, false);
    }
    _exit(0);
}

int main(int argc, char **argv)
{
    char pathl[64], pathr[64];
    if (argc >= 3) {
        snprintf(pathl, sizeof(pathl), "%s", argv[1]);
        snprintf(pathr, sizeof(pathr), "%s", argv[2]);
    } else {
        // 纯 C 扫描:逐个读 hidrawN/device/uevent 找 HID_NAME(不依赖 shell/popen)
        int found = 0;
        pathl[0] = pathr[0] = 0;
        for (int i = 0; i < 32 && found != 3; i++) {
            char p[96], buf[512];
            snprintf(p, sizeof(p), "/sys/class/hidraw/hidraw%d/device/uevent", i);
            int f = open(p, O_RDONLY);
            if (f < 0) continue;
            ssize_t n = read(f, buf, sizeof(buf) - 1);
            close(f);
            if (n <= 0) continue;
            buf[n] = 0;
            if (strstr(buf, "Joy-Con (L)")) {
                snprintf(pathl, sizeof(pathl), "/dev/hidraw%d", i); found |= 1;
            }
            if (strstr(buf, "Joy-Con (R)")) {
                snprintf(pathr, sizeof(pathr), "/dev/hidraw%d", i); found |= 2;
            }
        }
        if (found != 3) {
            fprintf(stderr, "hd-test: Joy-Con hidraw not found (found=0x%x)\n", found);
            return 1;
        }
        printf("auto-detected: L=%s R=%s\n", pathl, pathr);
    }
    int fdl = open(pathl, O_WRONLY | O_NONBLOCK);
    int fdr = open(pathr, O_WRONLY | O_NONBLOCK);
    g_fdl = fdl; g_fdr = fdr;
    signal(SIGTERM, on_term);
    signal(SIGINT, on_term);
    if (fdl < 0 || fdr < 0) {
        fprintf(stderr, "open hidraw: %s (L=%d R=%d)\n", strerror(errno), fdl, fdr);
        return 1;
    }
    printf("HD Rumble 演示:4 段循环播放(弹珠/心跳/雨滴/滑音),Ctrl+C 停止\n");

    struct band frame;
    unsigned long t0 = now_ms();
    unsigned long last = t0;
    // 段调度:每段 ms 时长
    const unsigned SEG_MS = 3500, GAP_MS = 900;
    int seg = -1;

    // 60Hz 节拍流式下发
    while (true) {
        unsigned long now = now_ms();
        if (now - last < 16) { usleep(2000); continue; }
        last = now;
        unsigned long t = now - t0;
        unsigned long cycle = t % (SEG_MS + GAP_MS);
        unsigned long ct;   // 段内时间
        int new_seg = t / (SEG_MS + GAP_MS);
        if (new_seg != seg) {
            seg = new_seg;
            printf("段 %d 开始\n", seg % 4);
        }
        (void)cycle;
        ct = t % (SEG_MS + GAP_MS);
        if (ct > SEG_MS) { stop_both(fdl, fdr); continue; }   // 段间隙静默
        float p = (float)ct / SEG_MS;   // 0..1
        // 段尾 120ms 渐隐:LRA 摆锤相位不突变,消除段间切换的撞壳「嘈噔」
        const unsigned FADE_MS = 120;
        float fade = (ct > SEG_MS - FADE_MS) ? (float)(SEG_MS - ct) / FADE_MS : 1.0f;

        switch (seg % 4) {   // 4 段:弹珠/心跳/雨滴/滑音(引擎段撞壳问题多,移除)
        case 0: {   // 玻璃弹珠滚动:HF 中频 + LF 包络起伏
            float env = 0.5f + 0.5f * sinf(p * 6.2831f * 3);
            frame.hf_freq = 0x18;
            frame.hf_amp = hf_amp(0.55f + 0.3f * sinf(p * 6.2831f * 7));
            frame.lf_freq = 0x10 + (unsigned char)(0x10 * sinf(p * 6.2831f * 2));
            frame.lf_amp = lf_amp(0.35f + 0.55f * env);
            break;
        }
        case 1: {   // 心跳:两次短促 LF 冲击 + 静默
            float thump = 0;
            if (ct < 180) thump = (ct < 60) ? 1.0f : (ct < 120 ? 0.55f : 0.15f);
            else if (ct > 300 && ct < 480) thump = (ct < 360) ? 0.85f : (ct < 420 ? 0.45f : 0.1f);
            frame.hf_freq = 0x14; frame.hf_amp = hf_amp(thump * 0.25f);
            frame.lf_freq = 0x08; frame.lf_amp = lf_amp(thump);
            break;
        }
        case 2: {   // 雨滴颗粒:HF 随机脉冲
            float drop = ((ct / 90) % 2 == 0 && (ct % 90) < 45) ? 0.5f : 0.04f;
            frame.hf_freq = 0x24 + (ct % 3) * 4;
            frame.hf_amp = hf_amp(drop);
            frame.lf_freq = 0x18; frame.lf_amp = lf_amp(drop * 0.15f);
            break;
        }
        case 3: {   // 滑音:LF 扫频 41Hz->116Hz,恒定幅度
                    // 原扫到 620Hz 的高频尾段(p>=0.5)会把摆锤顶到行程末端撞壳,砍掉,
                    // 段尾剩余时间直接静音
            if (p >= 0.5f) { stop_both(fdl, fdr); continue; }
            frame.lf_freq = 0x01 + (unsigned char)(p * 0x60);
            frame.lf_amp = lf_amp(0.6f);
            frame.hf_freq = 0x20; frame.hf_amp = hf_amp(0.12f);
            break;
        }
        }
        // fade 应用到两个频带的幅度(在编码函数的 clamp 之内乘,保序)
        frame.hf_amp = (unsigned char)(frame.hf_amp * fade);
        frame.lf_amp = (unsigned char)(frame.lf_amp * fade);
        send_both(fdl, fdr, frame);
    }
    return 0;
}
