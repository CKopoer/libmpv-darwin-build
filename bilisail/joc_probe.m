// Run against a local MP4 containing one independently identified E-AC-3 JOC
// track. AVFoundation supplies the container's dec3 cookie, mpv the actual
// compressed access units, timestamps and master timeline.
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <mpv/client.h>
#include <math.h>
#include <stdio.h>

extern int bilisail_joc_probe_install(mpv_handle *, void *,
    void (*)(void *, const unsigned char *, int, double, double));

@interface Packet : NSObject
@property(nonatomic, copy) NSData *data;
@property(nonatomic) double pts;
@property(nonatomic) double duration;
@end
@implementation Packet
@end

@interface PacketQueue : NSObject
@property(nonatomic, strong) NSMutableArray<Packet *> *pending;
@property(nonatomic) NSUInteger resets;
@property(nonatomic) BOOL overflow;
@end
@implementation PacketQueue
@end

static void accept_packet(void *context, const unsigned char *bytes, int length,
                          double pts, double duration) {
    @autoreleasepool {
        PacketQueue *queue = (__bridge PacketQueue *)context;
        @synchronized (queue) {
            if (!bytes) {
                queue.resets++;
                [queue.pending removeAllObjects];
                return;
            }
            if (length <= 0 || length > 65536 || !isfinite(pts) || queue.pending.count >= 128) {
                queue.overflow = YES;
                return;
            }
            Packet *packet = [Packet new];
            packet.data = [NSData dataWithBytes:bytes length:length];
            packet.pts = pts;
            packet.duration = duration;
            [queue.pending addObject:packet];
        }
    }
}

static CMSampleBufferRef make_sample(Packet *packet, CMAudioFormatDescriptionRef format) {
    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format);
    if (!asbd || asbd->mSampleRate <= 0) return NULL;
    CMBlockBufferRef block = NULL;
    size_t length = packet.data.length;
    if (CMBlockBufferCreateWithMemoryBlock(NULL, NULL, length, NULL, NULL, 0, length,
            kCMBlockBufferAssureMemoryNowFlag, &block) != noErr) return NULL;
    CMSampleBufferRef sample = NULL;
    if (CMBlockBufferReplaceDataBytes(packet.data.bytes, block, 0, length) == noErr) {
        AudioStreamPacketDescription desc = {0, 0, (UInt32)length};
        if (!asbd->mFramesPerPacket && isfinite(packet.duration) && packet.duration > 0)
            desc.mVariableFramesInPacket = (UInt32)llround(packet.duration * asbd->mSampleRate);
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(NULL, block, format, 1,
            CMTimeMakeWithSeconds(packet.pts, (int32_t)asbd->mSampleRate), &desc, &sample);
    }
    CFRelease(block);
    return sample;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) { fprintf(stderr, "usage: joc-probe single-JOC-track.mp4\n"); return 2; }
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:
            [NSString stringWithUTF8String:argv[1]]] options:nil];
        NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeAudio];
        if (tracks.count != 1 || tracks.firstObject.formatDescriptions.count != 1) return 2;
        CMAudioFormatDescriptionRef fmt = (__bridge CMAudioFormatDescriptionRef)
            tracks.firstObject.formatDescriptions.firstObject;
        const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt);
        if (!asbd || (asbd->mFormatID != kAudioFormatEnhancedAC3 && asbd->mFormatID != 'ec+3')) return 2;
        size_t listSize = 0;
        const AudioFormatListItem *formats = CMAudioFormatDescriptionGetFormatList(fmt, &listSize);
        BOOL atmosID = asbd->mFormatID == 'ec+3';
        for (size_t i = 0; i < listSize / sizeof(*formats); ++i)
            atmosID |= formats[i].mASBD.mFormatID == 'ec+3';
        size_t cookieSize = 0;
        CMAudioFormatDescriptionGetMagicCookie(fmt, &cookieSize);
        CFRetain(fmt);
        AVSampleBufferAudioRenderer *renderer = [AVSampleBufferAudioRenderer new];
        AVSampleBufferRenderSynchronizer *sync = [AVSampleBufferRenderSynchronizer new];
        sync.delaysRateChangeUntilHasSufficientMediaData = NO;
        [sync addRenderer:renderer];
        PacketQueue *queue = [PacketQueue new];
        queue.pending = [NSMutableArray array];
        mpv_handle *mpv = mpv_create();
        if (!mpv || bilisail_joc_probe_install(mpv, (__bridge void *)queue, accept_packet) < 0 ||
            mpv_set_option_string(mpv, "vid", "no") < 0 ||
            mpv_set_option_string(mpv, "ao", "null") < 0 ||
            mpv_set_option_string(mpv, "audio-buffer", "0.15") < 0 ||
            mpv_initialize(mpv) < 0) return 2;
        const char *load[] = {"loadfile", argv[1], NULL};
        if (mpv_command(mpv, load) < 0) return 2;
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        int stage = 0, count = 0, afterSeek = 0;
        size_t bytes = 0;
        NSUInteger generation = 0, beforeSeek = 0;
        float rate = -1;
        BOOL failed = NO, moved = NO;
        while (CFAbsoluteTimeGetCurrent() - start < 12 && !failed) {
            @autoreleasepool {
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
                double position = 0;
                if (mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &position) < 0) continue;
                int pause = 0, cache = 0, seeking = 0;
                mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &pause);
                mpv_get_property(mpv, "paused-for-cache", MPV_FORMAT_FLAG, &cache);
                mpv_get_property(mpv, "seeking", MPV_FORMAT_FLAG, &seeking);
                @synchronized (queue) {
                    if (queue.overflow) { failed = YES; break; }
                    if (generation != queue.resets) {
                        generation = queue.resets;
                        [sync setRate:0 time:kCMTimeInvalid];
                        [renderer flush];
                        rate = -1;
                    }
                    float desired = pause || cache || seeking ? 0 : 1;
                    if (rate != desired) {
                        rate = desired;
                        [sync setRate:rate time:CMTimeMakeWithSeconds(position, 48000)];
                    }
                    while (!seeking && queue.pending.count && renderer.readyForMoreMediaData) {
                        Packet *packet = queue.pending.firstObject;
                        CMSampleBufferRef sample = make_sample(packet, fmt);
                        if (!sample) { failed = YES; break; }
                        [renderer enqueueSampleBuffer:sample];
                        CFRelease(sample);
                        bytes += packet.data.length;
                        count++;
                        if (stage >= 2 && generation > beforeSeek && packet.pts >= 2.9) afterSeek++;
                        [queue.pending removeObjectAtIndex:0];
                    }
                }
                if (renderer.status == AVQueuedSampleBufferRenderingStatusFailed) { failed = YES; break; }
                if (stage == 0 && position >= 0.75 && count > 0) {
                    mpv_set_property_string(mpv, "pause", "yes"); stage = 1;
                } else if (stage == 1 && pause && rate == 0) {
                    beforeSeek = generation;
                    const char *seek[] = {"seek", "3", "absolute+exact", NULL};
                    if (mpv_command(mpv, seek) < 0) { failed = YES; break; }
                    stage = 2;
                    mpv_set_property_string(mpv, "pause", "no");
                } else if (stage == 2 && afterSeek > 4 && position > 4) {
                    moved = renderer.status == AVQueuedSampleBufferRenderingStatusRendering &&
                        fabs(CMTimeGetSeconds(sync.currentTime) - position) < 0.25;
                    if (moved) break;
                }
            }
        }
        printf("packets=%d bytes=%zu appleAtmosFormat=%d cookieBytes=%zu resets=%lu "
               "postSeekPackets=%d timelineAdvanced=%d rendererStatus=%ld error=%ld\n",
               count, bytes, atmosID, cookieSize, (unsigned long)generation, afterSeek, moved,
               (long)renderer.status, (long)renderer.error.code);
        [sync setRate:0 time:kCMTimeInvalid];
        [renderer flush];
        mpv_terminate_destroy(mpv);
        CFRelease(fmt);
        return !failed && moved ? 0 : 1;
    }
}
