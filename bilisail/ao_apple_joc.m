// SPDX-License-Identifier: LGPL-2.1-or-later
// E-AC-3 access units from the selected mpv decoder, timed by mpv's push AO.
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CMFormatDescriptionBridge.h>
#include <libavformat/avformat.h>
#include <libavutil/intreadwrite.h>
#include "audio/aframe.h"
#include "audio/format.h"
#include "audio/out/internal.h"
#include "common/common.h"
#include "common/global.h"
#include "common/msg.h"
#include "osdep/timer.h"

struct priv {
    bool started;
    int64_t last_clock;
    int64_t last_progress_ns;
    float volume;
    AVSampleBufferAudioRenderer *renderer;
    AVSampleBufferRenderSynchronizer *sync;
    CMAudioFormatDescriptionRef format;
    int64_t end;
    int submitted;
    bool failed;
};

// Walk the small MP4 generated below. Do not scan media payload for tag strings.
static const uint8_t *child(const uint8_t *p, size_t *size, const char tag[4])
{
    size_t left = *size;
    while (left >= 8) {
        size_t n = AV_RB32(p);
        if (n < 8 || n > left) break;
        if (memcmp(p + 4, tag, 4) == 0) {
            *size = n - 8;
            return p + 8;
        }
        left -= n;
        p += n;
    }
    return NULL;
}

static CMAudioFormatDescriptionRef make_format(struct ao *ao, AVBufferRef *unit, int frames)
{
    // MOV's dec3 writer parses the real bitstream, including dependent
    // substreams and the JOC complexity index. This also works for Matroska,
    // which need not carry a QuickTime sound description.
    AVFormatContext *mux = NULL;
    AVPacket *pkt = NULL;
    uint8_t *bytes = NULL;
    CMAudioFormatDescriptionRef fmt = NULL;
    if (avformat_alloc_output_context2(&mux, NULL, "mp4", NULL) < 0) goto done;
    AVStream *stream = avformat_new_stream(mux, NULL);
    if (!stream || avio_open_dyn_buf(&mux->pb) < 0) goto done;
    stream->codecpar->codec_type = AVMEDIA_TYPE_AUDIO;
    stream->codecpar->codec_id = AV_CODEC_ID_EAC3;
    stream->codecpar->sample_rate = ao->samplerate;
    stream->codecpar->frame_size = frames;
    av_channel_layout_default(&stream->codecpar->ch_layout, ao->channels.num);
    stream->time_base = (AVRational){1, ao->samplerate};
    if (avformat_write_header(mux, NULL) < 0) goto done;
    pkt = av_packet_alloc();
    if (!pkt || av_new_packet(pkt, unit->size) < 0) goto done;
    memcpy(pkt->data, unit->data, unit->size);
    pkt->duration = frames;
    // Two complete 6-block groups let movenc finalize its substream table.
    // This tiny in-memory file supplies metadata only.
    for (int i = 0; i < 12; i++) {
        pkt->pts = pkt->dts = i * frames;
        if (av_write_frame(mux, pkt) < 0) goto done;
    }
    if (av_write_trailer(mux) < 0) goto done;
    int len = avio_close_dyn_buf(mux->pb, &bytes);
    mux->pb = NULL;
    if (len <= 0 || !bytes) goto done;
    size_t size = len;
    const uint8_t *p = bytes;
    const char *path[] = {"moov", "trak", "mdia", "minf", "stbl", "stsd"};
    for (int i = 0; i < MP_ARRAY_SIZE(path); i++) {
        p = child(p, &size, path[i]);
        if (!p) goto done;
    }
    if (size < 16 || AV_RB32(p + 4) != 1) goto done;
    size -= 8;
    p = child(p + 8, &size, "ec-3");
    if (!p || CMAudioFormatDescriptionCreateFromBigEndianSoundDescriptionData(
            NULL, p - 8, size + 8, kCMSoundDescriptionFlavor_ISOFamily, &fmt) != noErr)
        goto done;
    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt);
    size_t list_size = 0;
    const AudioFormatListItem *list = CMAudioFormatDescriptionGetFormatList(fmt, &list_size);
    bool atmos = asbd && asbd->mFormatID == 'ec+3';
    for (size_t i = 0; list && i < list_size / sizeof(*list); i++)
        atmos |= list[i].mASBD.mFormatID == 'ec+3';
    if (!atmos) {
        CFRelease(fmt);
        fmt = NULL;
    }
done:
    if (mux && mux->pb) avio_close_dyn_buf(mux->pb, &bytes);
    av_free(bytes);
    av_packet_free(&pkt);
    avformat_free_context(mux);
    return fmt;
}

static void reject(struct ao *ao, const char *reason)
{
    struct priv *p = ao->priv;
    if (p->failed) return;
    p->failed = true;
    atomic_store(&ao->global->apple_joc_packets, 0);
    atomic_store(&ao->global->apple_joc_failed, true);
    MP_WARN(ao, "Compressed audio %s (OSStatus %ld); reopening PCM.\n",
            reason, (long)p->renderer.error.code);
    ao_request_reload(ao);
}

static int64_t now(struct ao *ao)
{
    struct priv *p = ao->priv;
    CMTime t = p->sync.currentTime;
    return CMTIME_IS_NUMERIC(t) ?
        CMTimeConvertScale(t, ao->samplerate, kCMTimeRoundingMethod_Default).value : 0;
}

static bool write_frame(struct ao *ao, void **data, int frames)
{
    @autoreleasepool {
        struct priv *p = ao->priv;
        struct mp_aframe *frame = *data;
        AVBufferRef *packet = mp_aframe_get_raw_avframe(frame)->buf[1];
        int samples = mp_aframe_get_size(frame);
        // Preserve contiguous timestamps unless the audio clock has already
        // passed the last queued sample after an actual underrun.
        int64_t clock = now(ao);
        int64_t start = MPMAX(clock, p->end);
        p->end = start + samples;
        if (!packet) return true; // mpv inserted a timed silence interval.
        if (!p->format) p->format = make_format(ao, packet, samples);
        CMBlockBufferRef block = NULL;
        CMSampleBufferRef sample = NULL;
        if (p->format && CMBlockBufferCreateWithMemoryBlock(NULL, NULL, packet->size,
                NULL, NULL, 0, packet->size, kCMBlockBufferAssureMemoryNowFlag, &block) == noErr &&
            CMBlockBufferReplaceDataBytes(packet->data, block, 0, packet->size) == noErr) {
            const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(p->format);
            AudioStreamPacketDescription desc = {0, asbd->mFramesPerPacket ? 0 : samples, (UInt32)packet->size};
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(NULL, block, p->format,
                1, CMTimeMake(start, ao->samplerate), &desc, &sample);
        }
        if (block) CFRelease(block);
        if (!sample) {
            reject(ao, "sample creation failed");
            return false;
        }
        // A demux packet and the trimmed decoder frame need not cover the
        // same number of samples. Scheduling a whole compressed packet into
        // a shorter slot makes it overlap the following packet.
        CMTime duration = CMSampleBufferGetDuration(sample);
        if (CMTIME_IS_NUMERIC(duration) &&
            CMTimeCompare(duration, CMTimeMake(samples, ao->samplerate)) != 0) {
            CFRelease(sample);
            reject(ao, "packet duration mismatch");
            return false;
        }
        [p->renderer enqueueSampleBuffer:sample];
        CFRelease(sample);
        if (p->submitted < INT_MAX) p->submitted++;
        return true;
    }
}

static void get_state(struct ao *ao, struct mp_pcm_state *s)
{
    @autoreleasepool {
        struct priv *p = ao->priv;
        float gain = atomic_load(&ao->gain);
        float volume = MPCLAMP(gain, 0, 1);
        if (volume != p->volume) {
            p->renderer.volume = volume;
            p->volume = volume;
        }
        int64_t clock = now(ao);
        int queued = MPCLAMP(p->end - clock, 0, ao->device_buffer);
        if (p->renderer.status == AVQueuedSampleBufferRenderingStatusFailed)
            reject(ao, "renderer failed");
        if (!p->failed && p->submitted &&
            p->renderer.status == AVQueuedSampleBufferRenderingStatusRendering) {
            atomic_store(&ao->global->apple_joc_packets, p->submitted);
        }
        // An incomplete preroll can leave the clock waiting without an error.
        // Paused and empty queues have no obligation to advance.
        int64_t wall = mp_time_ns();
        if (!p->started || !queued || clock != p->last_clock) {
            p->last_progress_ns = wall;
            p->last_clock = clock;
        } else if (wall - p->last_progress_ns > MP_TIME_S_TO_NS(2)) {
            reject(ao, "render clock stalled");
        }
        // Apple's ready flag is advisory. A route can keep it low until
        // there is less than one compressed packet of playback left. Keep
        // 250 ms scheduled in that case, within the normal device limit.
        int limit = p->renderer.readyForMoreMediaData ? ao->device_buffer : ao->samplerate / 4;
        int space = limit - queued;
        *s = (struct mp_pcm_state){
            .queued_samples = queued,
            .free_samples = !p->failed && space >= 1536 ? space : 0,
            .delay = (double)queued / ao->samplerate,
            .playing = queued > 0,
        };
    }
}

static bool set_pause(struct ao *ao, bool paused)
{
    struct priv *p = ao->priv;
    p->started = !paused;
    p->last_progress_ns = mp_time_ns();
    [p->sync setRate:paused ? 0 : 1];
    return true;
}
static void start(struct ao *ao) { set_pause(ao, false); }

static void reset(struct ao *ao)
{
    struct priv *p = ao->priv;
    p->started = false;
    [p->sync setRate:0 time:kCMTimeZero];
    [p->renderer flush];
    p->end = 0;
    p->submitted = 0;
    atomic_store(&ao->global->apple_joc_packets, 0);
}

static void uninit(struct ao *ao)
{
    struct priv *p = ao->priv;
    reset(ao);
    if (p->format) CFRelease(p->format);
    [p->sync release];
    [p->renderer release];
}

static int init(struct ao *ao)
{
    if (ao->format != AF_FORMAT_APPLE_JOC) return -1;
    struct priv *p = ao->priv;
#if TARGET_OS_IPHONE
    AVAudioSession *session = AVAudioSession.sharedInstance;
    if (![session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeMoviePlayback
            options:0 error:nil] || ![session setActive:YES error:nil]) return -1;
#endif
    p->renderer = [[AVSampleBufferAudioRenderer alloc] init];
    p->sync = [[AVSampleBufferRenderSynchronizer alloc] init];
    if (!p->renderer || !p->sync) {
        uninit(ao);
        return -1;
    }
    [p->sync addRenderer:p->renderer];
    p->sync.delaysRateChangeUntilHasSufficientMediaData = YES;
    p->volume = -1;
    // mpv also allocates a software queue of this size and drains both on
    // pause near EOF. Leave room for preroll while bounding that drain.
    ao->device_buffer = ao->samplerate / 2;
    return 0;
}

const struct ao_driver audio_out_apple_joc = {
    .description = "Apple compressed Dolby Digital Plus JOC",
    .name = "apple-joc",
    .write_frames = true,
    .write = write_frame,
    .init = init,
    .get_state = get_state,
    .start = start,
    .reset = reset,
    .set_pause = set_pause,
    .uninit = uninit,
    .priv_size = sizeof(struct priv),
};
