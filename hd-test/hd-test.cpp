// hd-test: Joy-Con HD Rumble 波形播放器 (hidraw 0x10 流式,60Hz)
// 用法: hd-test <hidrawL> <hidrawR>
// 波形内置,循环播放,共 5 段,每段之间停 1s
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <math.h>

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

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "用法: hd-test <hidrawL> <hidrawR>\n");
        return 1;
    }
    int fdl = open(argv[1], O_WRONLY | O_NONBLOCK);
    int fdr = open(argv[2], O_WRONLY | O_NONBLOCK);
    if (fdl < 0 || fdr < 0) {
        fprintf(stderr, "open hidraw: %s (L=%d R=%d)\n", strerror(errno), fdl, fdr);
        return 1;
    }
    printf("HD Rumble 演示:5 段循环播放,Ctrl+C 停止\n");

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
            printf("段 %d 开始\n", seg % 5);
        }
        (void)cycle;
        ct = t % (SEG_MS + GAP_MS);
        if (ct > SEG_MS) { stop_both(fdl, fdr); continue; }   // 段间隙静默
        float p = (float)ct / SEG_MS;   // 0..1

        switch (seg % 5) {
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
            float drop = ((ct / 90) % 2 == 0 && (ct % 90) < 45) ? 0.8f : 0.05f;
            frame.hf_freq = 0x24 + (ct % 3) * 4;
            frame.hf_amp = hf_amp(drop);
            frame.lf_freq = 0x18; frame.lf_amp = lf_amp(drop * 0.15f);
            break;
        }
        case 3: {   // 滑音:LF 频率扫频(40Hz->620Hz),恒定幅度
            unsigned char f = 0x01 + (unsigned char)(p * 0x60);
            frame.lf_freq = f; frame.lf_amp = lf_amp(0.8f);
            frame.hf_freq = 0x20; frame.hf_amp = hf_amp(0.12f);
            break;
        }
        case 4: {   // 引擎轰鸣:LF 低频 + 幅度颤动
            float rev = 0.4f + 0.35f * sinf(p * 6.2831f * 1.5f);
            frame.hf_freq = 0x10 + (unsigned char)(0x14 * p);
            frame.hf_amp = hf_amp(0.3f + 0.25f * rev);
            frame.lf_freq = 0x06 + (unsigned char)(0x10 * p);
            frame.lf_amp = lf_amp(rev);
            break;
        }
        }
        send_both(fdl, fdr, frame);
    }
    return 0;
}
