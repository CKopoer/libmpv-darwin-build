// Test-only notification injection against the production mpv AO. No audio
// route or head-tracking preference needs to be changed on the CI machine.
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#include <mpv/client.h>
#include <stdio.h>
#include <string.h>

static AVSampleBufferAudioRenderer *output;
static id lastSample, expectedSample;
static BOOL replayed;
static void (*systemEnqueue)(id, SEL, CMSampleBufferRef);

static void enqueue(AVSampleBufferAudioRenderer *renderer, SEL sel, CMSampleBufferRef sample)
{
    systemEnqueue(renderer, sel, sample);
    @synchronized ([AVSampleBufferAudioRenderer class]) {
        output = renderer;
        lastSample = (__bridge id)sample;
        if (lastSample == expectedSample) replayed = YES;
    }
}

static void tick(void)
{
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}

static BOOL hasLead(void)
{
    @synchronized ([AVSampleBufferAudioRenderer class]) {
        if (!lastSample) return NO;
        CMTime clock = CMTimebaseGetTime(output.timebase);
        CMTime pts = CMSampleBufferGetPresentationTimeStamp((__bridge CMSampleBufferRef)lastSample);
        return CMTimeGetSeconds(clock) > 0.15 && CMTimeGetSeconds(CMTimeSubtract(pts, clock)) > 0.15;
    }
}

static BOOL exercise(mpv_handle *player, NSNotificationName name, BOOL pause)
{
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 5;
    while (!hasLead() && CFAbsoluteTimeGetCurrent() < deadline) tick();
    if (!hasLead()) return NO;
    if (pause && mpv_set_property_string(player, "pause", "yes") < 0) return NO;
    AVSampleBufferAudioRenderer *renderer;
    @synchronized ([AVSampleBufferAudioRenderer class]) {
        renderer = output;
        expectedSample = lastSample;
        replayed = NO;
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:name object:renderer];
    if (pause) {
        CFAbsoluteTime until = CFAbsoluteTimeGetCurrent() + 0.2;
        while (CFAbsoluteTimeGetCurrent() < until) tick();
        if (CMTimebaseGetEffectiveRate(renderer.timebase) != 0 ||
            mpv_set_property_string(player, "pause", "no") < 0) return NO;
    }
    deadline = CFAbsoluteTimeGetCurrent() + 1.5;
    while (CFAbsoluteTimeGetCurrent() < deadline) {
        tick();
        @synchronized ([AVSampleBufferAudioRenderer class]) {
            if (replayed) return YES;
        }
    }
    return NO;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc != 2) return 2;
        Method method = class_getInstanceMethod([AVSampleBufferAudioRenderer class], @selector(enqueueSampleBuffer:));
        systemEnqueue = (void *)method_setImplementation(method, (IMP)enqueue);
        mpv_handle *player = mpv_create();
        if (!player || mpv_set_option_string(player, "vid", "no") < 0 ||
            mpv_set_option_string(player, "audio-spdif", "apple-joc") < 0 ||
            mpv_initialize(player) < 0) return 2;
        const char *load[] = {"loadfile", argv[1], NULL};
        if (mpv_command(player, load) < 0) return 2;
        BOOL changed = exercise(player, AVSampleBufferAudioRendererOutputConfigurationDidChangeNotification, NO);
        BOOL flushed = exercise(player, AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification, YES);
        char *ao = mpv_get_property_string(player, "current-ao");
        BOOL joc = ao && !strcmp(ao, "apple-joc");
        mpv_free(ao);
        mpv_terminate_destroy(player);
        fprintf(stderr, "configurationReplay=%d automaticFlushReplayAfterPause=%d appleJoc=%d\n",
                changed, flushed, joc);
        return changed && flushed && joc ? 0 : 1;
    }
}
