// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Collider — standalone app entry point.
// Reuses RealtimeRunner, AVAudioEngine, CoreMIDI from Magenta RT standalone.
// Adds shared state for MIDI note visualization and audio waveform display.

#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMIDI/CoreMIDI.h>
#import <CoreAudio/CoreAudio.h>
#import "ColliderAppController.h"
#import "../common/objc/MagentaSettings.h"
#include <magentart/realtime_runner.h>
#include "../common/cpp/magenta_paths.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>

using magentart::core::RealtimeRunner;

namespace {

static inline float confabClamp(float x, float lo, float hi) {
    return std::max(lo, std::min(hi, x));
}

static inline float confabLerp(float a, float b, float t) {
    return a + (b - a) * t;
}

static inline float confabFold(float x) {
    for (int i = 0; i < 8; ++i) {
        if (x > 1.0f) x = 2.0f - x;
        else if (x < -1.0f) x = -2.0f - x;
        else break;
    }
    return confabClamp(x, -1.0f, 1.0f);
}

struct ConfabulatorDsp {
    static constexpr int kRate = 48000;
    static constexpr int kDelaySize = kRate * 2;
    static constexpr float kPi = 3.14159265358979323846f;

    std::array<float, kDelaySize> delayL{};
    std::array<float, kDelaySize> delayR{};
    std::array<float, kDelaySize> bodyL{};
    std::array<float, kDelaySize> bodyR{};
    std::array<float, kDelaySize> pitchL{};
    std::array<float, kDelaySize> pitchR{};
    std::array<float, kDelaySize> stutterL{};
    std::array<float, kDelaySize> stutterR{};
    std::array<float, 4> smearStateL{};
    std::array<float, 4> smearStateR{};

    int delayIndex = 0;
    int bodyIndex = 0;
    int pitchWrite = 0;
    double pitchRead = 0.0;
    int stutterWrite = 0;
    int stutterBase = 0;
    int stutterRead = 0;
    int crushCountdown = 0;
    float crushHoldL = 0.0f;
    float crushHoldR = 0.0f;
    float ringPhase = 0.0f;
    std::uint32_t rng = 0xC0FFEEu;

    float randomBipolar() {
        rng = rng * 1664525u + 1013904223u;
        float unit = (float)((rng >> 8) & 0x00FFFFFFu) / 16777215.0f;
        return unit * 2.0f - 1.0f;
    }

    void process(ColliderSharedState* shared, float* left, float* right, int count) {
        if (!shared) return;
        const float wet = confabClamp(shared->fxWet.load(std::memory_order_relaxed), 0.0f, 1.0f);
        if (wet <= 0.0001f) return;

        const float drive = confabClamp(shared->fxDrive.load(std::memory_order_relaxed), 0.0f, 1.0f);
        const float fold = confabClamp(shared->fxFold.load(std::memory_order_relaxed), 0.0f, 1.0f);
        const float crush = confabClamp(shared->fxCrush.load(std::memory_order_relaxed), 0.0f, 1.0f);
        const float ring = confabClamp(shared->fxRing.load(std::memory_order_relaxed), 0.0f, 1.0f);
        const float comb = confabClamp(shared->fxComb.load(std::memory_order_relaxed), 0.0f, 1.0f);
        const float body = confabClamp(shared->fxBody.load(std::memory_order_relaxed), 0.0f, 1.0f);
        const float smear = confabClamp(shared->fxSmear.load(std::memory_order_relaxed), 0.0f, 1.0f);
        const float stutter = confabClamp(shared->fxStutter.load(std::memory_order_relaxed), 0.0f, 1.0f);
        const float pitch = confabClamp(shared->fxPitch.load(std::memory_order_relaxed), 0.0f, 1.0f);
        const float harmonics = confabClamp(shared->fxHarmonics.load(std::memory_order_relaxed), 0.0f, 1.0f);
        const float noise = confabClamp(shared->fxNoise.load(std::memory_order_relaxed), 0.0f, 1.0f);

        const float driveGain = 1.0f + drive * drive * 72.0f;
        const float ringFreq = 18.0f + ring * ring * 6200.0f;
        const float ringStep = (2.0f * kPi * ringFreq) / (float)kRate;
        const int combDelay = std::max(1, (int)(24.0f + comb * comb * 11800.0f));
        const float combFeedback = 0.06f + comb * 0.62f;
        const int crushHold = std::max(1, (int)(1.0f + crush * crush * 220.0f));
        const float crushLevels = std::max(4.0f, 65536.0f * std::pow(1.0f / 16384.0f, crush));
        const int stutterLen = std::max(96, (int)(240.0f + (1.0f - stutter) * (1.0f - stutter) * 18000.0f));
        const float pitchMix = confabClamp(std::fabs(pitch - 0.5f) * 2.0f, 0.0f, 1.0f);
        const float pitchRate = std::pow(2.0f, ((pitch - 0.5f) * 24.0f) / 12.0f);
        const int bodyBase = std::max(11, (int)(19.0f + body * body * 860.0f));
        const float bodyFeedback = 0.04f + body * 0.48f;
        const float smearGain = 0.12f + smear * 0.68f;

        for (int i = 0; i < count; ++i) {
            const float dryL = left[i];
            const float dryR = right[i];
            float xL = dryL;
            float xR = dryR;

            if (noise > 0.0f) {
                const float amp = noise * noise * 0.035f;
                xL += randomBipolar() * amp;
                xR += randomBipolar() * amp;
            }

            if (harmonics > 0.0f) {
                auto bend = [harmonics](float x) {
                    float odd = x * x * x;
                    float buzz = std::sin(x * kPi * (3.0f + harmonics * 11.0f));
                    return x + harmonics * (odd * 0.72f + buzz * 0.22f);
                };
                xL = bend(xL);
                xR = bend(xR);
            }

            if (drive > 0.0f) {
                xL = std::tanh(xL * driveGain);
                xR = std::tanh(xR * driveGain);
            }

            if (fold > 0.0f) {
                xL = confabLerp(xL, confabFold(xL * (1.0f + fold * 12.0f)), fold);
                xR = confabLerp(xR, confabFold(xR * (1.0f + fold * 12.0f)), fold);
            }

            if (ring > 0.0f) {
                float mod = std::sin(ringPhase);
                ringPhase += ringStep;
                if (ringPhase > 2.0f * kPi) ringPhase -= 2.0f * kPi;
                xL = confabLerp(xL, xL * mod, ring);
                xR = confabLerp(xR, xR * -mod, ring);
            }

            if (pitchMix > 0.0001f) {
                pitchL[pitchWrite] = xL;
                pitchR[pitchWrite] = xR;
                int readIndex = ((int)pitchRead + kDelaySize) % kDelaySize;
                float pL = pitchL[readIndex];
                float pR = pitchR[readIndex];
                xL = confabLerp(xL, pL, pitchMix * 0.82f);
                xR = confabLerp(xR, pR, pitchMix * 0.82f);
                pitchRead += pitchRate;
                while (pitchRead >= kDelaySize) pitchRead -= kDelaySize;
                pitchWrite = (pitchWrite + 1) % kDelaySize;
            } else {
                pitchL[pitchWrite] = xL;
                pitchR[pitchWrite] = xR;
                pitchRead = (double)((pitchWrite + kDelaySize - 4096) % kDelaySize);
                pitchWrite = (pitchWrite + 1) % kDelaySize;
            }

            if (comb > 0.0f) {
                int read = (delayIndex - combDelay + kDelaySize) % kDelaySize;
                float dL = delayL[read];
                float dR = delayR[read];
                delayL[delayIndex] = confabClamp(xL + dL * combFeedback, -2.0f, 2.0f);
                delayR[delayIndex] = confabClamp(xR + dR * combFeedback, -2.0f, 2.0f);
                delayIndex = (delayIndex + 1) % kDelaySize;
                xL = confabLerp(xL, xL + dL * 1.12f, comb);
                xR = confabLerp(xR, xR + dR * 1.12f, comb);
            } else {
                delayL[delayIndex] = xL;
                delayR[delayIndex] = xR;
                delayIndex = (delayIndex + 1) % kDelaySize;
            }

            if (body > 0.0f) {
                const int offsets[6] = {
                    bodyBase,
                    (int)(bodyBase * 1.51f),
                    (int)(bodyBase * 2.07f),
                    (int)(bodyBase * 2.89f),
                    (int)(bodyBase * 4.11f),
                    (int)(bodyBase * 5.43f)
                };
                const float gains[6] = {0.72f, -0.58f, 0.42f, -0.33f, 0.24f, -0.18f};
                float rL = 0.0f;
                float rR = 0.0f;
                for (int tap = 0; tap < 6; ++tap) {
                    int read = (bodyIndex - offsets[tap] + kDelaySize) % kDelaySize;
                    rL += bodyL[read] * gains[tap];
                    rR += bodyR[read] * gains[tap];
                }
                bodyL[bodyIndex] = confabClamp(xL + rL * bodyFeedback, -2.0f, 2.0f);
                bodyR[bodyIndex] = confabClamp(xR + rR * bodyFeedback, -2.0f, 2.0f);
                bodyIndex = (bodyIndex + 1) % kDelaySize;
                xL = confabLerp(xL, std::tanh(xL + rL * 1.35f), body);
                xR = confabLerp(xR, std::tanh(xR + rR * 1.35f), body);
            } else {
                bodyL[bodyIndex] = xL;
                bodyR[bodyIndex] = xR;
                bodyIndex = (bodyIndex + 1) % kDelaySize;
            }

            if (smear > 0.0f) {
                float sL = xL;
                float sR = xR;
                for (int stage = 0; stage < 4; ++stage) {
                    float delayedL = smearStateL[stage];
                    float delayedR = smearStateR[stage];
                    float yL = delayedL - smearGain * sL;
                    float yR = delayedR - smearGain * sR;
                    smearStateL[stage] = sL + smearGain * yL;
                    smearStateR[stage] = sR + smearGain * yR;
                    sL = yL;
                    sR = yR;
                }
                xL = confabLerp(xL, sL, smear);
                xR = confabLerp(xR, sR, smear);
            }

            stutterL[stutterWrite] = xL;
            stutterR[stutterWrite] = xR;
            stutterWrite = (stutterWrite + 1) % kDelaySize;
            if (stutter > 0.0f) {
                if (stutterRead <= 0 || stutterRead >= stutterLen) {
                    stutterBase = (stutterWrite - stutterLen + kDelaySize) % kDelaySize;
                    stutterRead = 0;
                }
                int idx = (stutterBase + stutterRead) % kDelaySize;
                stutterRead++;
                xL = confabLerp(xL, stutterL[idx], stutter);
                xR = confabLerp(xR, stutterR[idx], stutter);
            } else {
                stutterRead = 0;
            }

            if (crush > 0.0f) {
                if (crushCountdown <= 0) {
                    crushHoldL = std::round(xL * crushLevels) / crushLevels;
                    crushHoldR = std::round(xR * crushLevels) / crushLevels;
                    crushCountdown = crushHold;
                }
                crushCountdown--;
                xL = confabLerp(xL, crushHoldL, crush);
                xR = confabLerp(xR, crushHoldR, crush);
            }

            float yL = confabClamp(confabLerp(dryL, xL, wet), -1.0f, 1.0f);
            float yR = confabClamp(confabLerp(dryR, xR, wet), -1.0f, 1.0f);

            left[i] = confabClamp(yL, -1.0f, 1.0f);
            right[i] = confabClamp(yR, -1.0f, 1.0f);
        }
    }
};

}

// ─── Settings Window Controller ─────────────────────────────────────────────
// Full settings panel: Model, Generation params, Audio I/O, MIDI sources.
// Accessible from app menu (Cmd+,) or from the gear icon in the React UI.

@interface ColliderSettingsController : NSWindowController <NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, assign) MIDIClientRef midiClient;
@property (nonatomic, assign) MIDIPortRef midiInputPort;
@property (nonatomic, strong) AVAudioEngine* audioEngine;
@property (nonatomic, strong) NSMutableSet<NSNumber*>* connectedSources;
@property (nonatomic, weak) ColliderAppController* appController;
- (void)refreshMIDISources;
- (void)refreshAll;
@end

@implementation ColliderSettingsController {
    // Model
    NSTextField* _modelNameLabel;
    // Generation
    NSSlider* _temperatureSlider;   NSTextField* _temperatureValue;
    NSSlider* _topkSlider;          NSTextField* _topkValue;
    NSSlider* _cfgMusicCoCaSlider;  NSTextField* _cfgMusicCoCaValue;
    NSSlider* _cfgNotesSlider;      NSTextField* _cfgNotesValue;
    NSSlider* _cfgDrumsSlider;      NSTextField* _cfgDrumsValue;
    NSSlider* _unmaskWidthSlider;   NSTextField* _unmaskWidthValue;
    NSSlider* _volumeSlider;        NSTextField* _volumeValue;
    NSPopUpButton* _bufferSizePopup;
    NSButton* _muteCheckbox;
    NSButton* _drumModeCheckbox;
    // Audio
    NSTextField* _audioDeviceLabel;
    NSTextField* _audioSampleRateLabel;
    NSTextField* _audioBufferSizeLabel;
    // MIDI
    NSTextField* _midiVirtualLabel;
    NSTableView* _midiTableView;
    NSMutableArray<NSDictionary*>* _midiSources;
    NSButton* _computerKeyboardMidiCheckbox;
}

// ── Helpers for building UI ──

static NSTextField* makeLabel(NSString* text, CGFloat x, CGFloat y, CGFloat w) {
    NSTextField* label = [NSTextField labelWithString:text];
    label.frame = NSMakeRect(x, y, w, 16);
    label.font = [NSFont systemFontOfSize:11];
    label.textColor = [NSColor secondaryLabelColor];
    return label;
}

static NSTextField* makeValue(CGFloat x, CGFloat y) {
    NSTextField* label = [NSTextField labelWithString:@"—"];
    label.frame = NSMakeRect(x, y, 50, 16);
    label.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    label.alignment = NSTextAlignmentRight;
    return label;
}

static NSSlider* makeSlider(CGFloat x, CGFloat y, CGFloat w, double min, double max, double val, id target, SEL action) {
    NSSlider* slider = [[NSSlider alloc] initWithFrame:NSMakeRect(x, y, w, 20)];
    slider.minValue = min;
    slider.maxValue = max;
    slider.doubleValue = val;
    slider.continuous = YES;
    slider.target = target;
    slider.action = action;
    return slider;
}

- (instancetype)init {
    CGFloat W = 480, H = 740;
    NSRect frame = NSMakeRect(0, 0, W, H);
    NSWindow* window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"Settings";
    window.releasedWhenClosed = NO;

    self = [super initWithWindow:window];
    if (!self) return nil;
    _connectedSources = [NSMutableSet set];
    _midiSources = [NSMutableArray array];
    window.delegate = self;

    NSView* c = window.contentView;
    CGFloat pad = 20, col2 = 110, sliderW = 280, valX = W - 70;
    CGFloat y = H - 40;

    // ── Model ──
    NSTextField* modelHeader = [NSTextField labelWithString:@"Model"];
    modelHeader.font = [NSFont boldSystemFontOfSize:13];
    modelHeader.frame = NSMakeRect(pad, y, 200, 18);
    [c addSubview:modelHeader];
    y -= 28;

    NSButton* loadBtn = [NSButton buttonWithTitle:@"Load Model..." target:self action:@selector(loadModelClicked:)];
    loadBtn.frame = NSMakeRect(pad, y, 120, 24);
    loadBtn.bezelStyle = NSBezelStyleRounded;
    loadBtn.font = [NSFont systemFontOfSize:12];
    [c addSubview:loadBtn];

    _modelNameLabel = [NSTextField labelWithString:@"No model loaded"];
    _modelNameLabel.frame = NSMakeRect(pad + 128, y + 3, W - pad - 148, 16);
    _modelNameLabel.font = [NSFont systemFontOfSize:11];
    _modelNameLabel.textColor = [NSColor secondaryLabelColor];
    _modelNameLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [c addSubview:_modelNameLabel];
    y -= 24;



    NSBox* sep0 = [[NSBox alloc] initWithFrame:NSMakeRect(pad, y, W - 2 * pad, 1)];
    sep0.boxType = NSBoxSeparator;
    [c addSubview:sep0];
    y -= 24;

    // ── Generation ──
    NSTextField* genHeader = [NSTextField labelWithString:@"Generation"];
    genHeader.font = [NSFont boldSystemFontOfSize:13];
    genHeader.frame = NSMakeRect(pad, y, 200, 18);
    [c addSubview:genHeader];
    y -= 26;

    // Volume
    [c addSubview:makeLabel(@"Volume (dB)", pad, y, 90)];
    _volumeSlider = makeSlider(col2, y - 2, sliderW, -60, 12, 0, self, @selector(volumeChanged:));
    [c addSubview:_volumeSlider];
    _volumeValue = makeValue(valX, y); [c addSubview:_volumeValue];
    y -= 26;

    // Temperature
    [c addSubview:makeLabel(@"Temperature", pad, y, 90)];
    _temperatureSlider = makeSlider(col2, y - 2, sliderW, 0, 3, kMagentaDefaultTemperature, self, @selector(temperatureChanged:));
    [c addSubview:_temperatureSlider];
    _temperatureValue = makeValue(valX, y); [c addSubview:_temperatureValue];
    y -= 26;

    // Top-K
    [c addSubview:makeLabel(@"Top-K", pad, y, 90)];
    _topkSlider = makeSlider(col2, y - 2, sliderW, 1, 1024, kMagentaDefaultTopK, self, @selector(topkChanged:));
    [c addSubview:_topkSlider];
    _topkValue = makeValue(valX, y); [c addSubview:_topkValue];
    y -= 26;



    // CFG-MusicCoCa
    [c addSubview:makeLabel(@"CFG-MusicCoCa", pad, y, 90)];
    _cfgMusicCoCaSlider = makeSlider(col2, y - 2, sliderW, 0, 5, kColliderDefaultCfgMusicCoCa, self, @selector(cfgMusicCoCaChanged:));
    [c addSubview:_cfgMusicCoCaSlider];
    _cfgMusicCoCaValue = makeValue(valX, y); [c addSubview:_cfgMusicCoCaValue];
    y -= 26;

    // CFG-Notes
    [c addSubview:makeLabel(@"CFG-Notes", pad, y, 90)];
    _cfgNotesSlider = makeSlider(col2, y - 2, sliderW, 0, 5, kColliderDefaultCfgNotes, self, @selector(cfgNotesChanged:));
    [c addSubview:_cfgNotesSlider];
    _cfgNotesValue = makeValue(valX, y); [c addSubview:_cfgNotesValue];
    y -= 26;

    // CFG-Drums
    [c addSubview:makeLabel(@"CFG-Drums", pad, y, 90)];
    _cfgDrumsSlider = makeSlider(col2, y - 2, sliderW, 0, 5, 1, self, @selector(cfgDrumsChanged:));
    [c addSubview:_cfgDrumsSlider];
    _cfgDrumsValue = makeValue(valX, y); [c addSubview:_cfgDrumsValue];
    y -= 26;

    // Unmask width
    [c addSubview:makeLabel(@"Unmask width", pad, y, 90)];
    _unmaskWidthSlider = makeSlider(col2, y - 2, sliderW, 0, 127, 0, self, @selector(unmaskWidthChanged:));
    [c addSubview:_unmaskWidthSlider];
    _unmaskWidthValue = makeValue(valX, y); [c addSubview:_unmaskWidthValue];
    y -= 30;

    // Buffer size
    [c addSubview:makeLabel(@"Buffer Size", pad, y + 2, 90)];
    _bufferSizePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(col2, y, 100, 22) pullsDown:NO];
    [_bufferSizePopup addItemsWithTitles:@[@"2048", @"4096", @"8192"]];
    _bufferSizePopup.font = [NSFont systemFontOfSize:11];
    _bufferSizePopup.target = self;
    _bufferSizePopup.action = @selector(bufferSizeChanged:);
    [c addSubview:_bufferSizePopup];

    _muteCheckbox = [NSButton checkboxWithTitle:@"Mute" target:self action:@selector(muteChanged:)];
    _muteCheckbox.frame = NSMakeRect(col2 + 120, y + 1, 60, 18);
    _muteCheckbox.font = [NSFont systemFontOfSize:11];
    [c addSubview:_muteCheckbox];

    _drumModeCheckbox = [NSButton checkboxWithTitle:@"Drum Mode" target:self action:@selector(drumModeChanged:)];
    _drumModeCheckbox.frame = NSMakeRect(col2 + 190, y + 1, 100, 18);
    _drumModeCheckbox.font = [NSFont systemFontOfSize:11];
    [c addSubview:_drumModeCheckbox];
    y -= 20;

    // Reset defaults
    NSButton* resetBtn = [NSButton buttonWithTitle:@"Reset Defaults" target:self action:@selector(resetDefaults:)];
    resetBtn.frame = NSMakeRect(pad, y, 120, 20);
    resetBtn.bezelStyle = NSBezelStyleInline;
    resetBtn.font = [NSFont systemFontOfSize:11];
    [c addSubview:resetBtn];
    y -= 16;

    NSBox* sep1 = [[NSBox alloc] initWithFrame:NSMakeRect(pad, y, W - 2 * pad, 1)];
    sep1.boxType = NSBoxSeparator;
    [c addSubview:sep1];
    y -= 24;

    // ── Audio Output ──
    NSTextField* audioHeader = [NSTextField labelWithString:@"Audio Output"];
    audioHeader.font = [NSFont boldSystemFontOfSize:13];
    audioHeader.frame = NSMakeRect(pad, y, 200, 18);
    [c addSubview:audioHeader];
    y -= 22;

    [c addSubview:makeLabel(@"Device:", pad, y, 55)];
    _audioDeviceLabel = [NSTextField labelWithString:@"—"];
    _audioDeviceLabel.frame = NSMakeRect(pad + 60, y, 350, 16);
    _audioDeviceLabel.font = [NSFont systemFontOfSize:11];
    [c addSubview:_audioDeviceLabel];
    y -= 18;

    [c addSubview:makeLabel(@"Sample Rate:", pad, y, 80)];
    _audioSampleRateLabel = [NSTextField labelWithString:@"—"];
    _audioSampleRateLabel.frame = NSMakeRect(pad + 85, y, 200, 16);
    _audioSampleRateLabel.font = [NSFont systemFontOfSize:11];
    [c addSubview:_audioSampleRateLabel];
    y -= 18;

    [c addSubview:makeLabel(@"Buffer Size:", pad, y, 80)];
    _audioBufferSizeLabel = [NSTextField labelWithString:@"—"];
    _audioBufferSizeLabel.frame = NSMakeRect(pad + 85, y, 200, 16);
    _audioBufferSizeLabel.font = [NSFont systemFontOfSize:11];
    [c addSubview:_audioBufferSizeLabel];
    y -= 16;

    NSBox* sep2 = [[NSBox alloc] initWithFrame:NSMakeRect(pad, y, W - 2 * pad, 1)];
    sep2.boxType = NSBoxSeparator;
    [c addSubview:sep2];
    y -= 24;

    // ── MIDI Input ──
    NSTextField* midiHeader = [NSTextField labelWithString:@"MIDI Input"];
    midiHeader.font = [NSFont boldSystemFontOfSize:13];
    midiHeader.frame = NSMakeRect(pad, y, 200, 18);
    [c addSubview:midiHeader];
    y -= 20;

    _midiVirtualLabel = [NSTextField labelWithString:@"Virtual port: CONFABULATOR Input"];
    _midiVirtualLabel.frame = NSMakeRect(pad, y, 400, 16);
    _midiVirtualLabel.font = [NSFont systemFontOfSize:10];
    _midiVirtualLabel.textColor = [NSColor tertiaryLabelColor];
    [c addSubview:_midiVirtualLabel];
    y -= 20;

    _computerKeyboardMidiCheckbox = [NSButton checkboxWithTitle:@"Use computer keyboard as MIDI input (Ableton layout)"
                                                         target:self
                                                         action:@selector(computerKeyboardMidiChanged:)];
    _computerKeyboardMidiCheckbox.frame = NSMakeRect(pad, y, 400, 18);
    _computerKeyboardMidiCheckbox.font = [NSFont systemFontOfSize:11];
    [c addSubview:_computerKeyboardMidiCheckbox];
    y -= 20;

    [c addSubview:makeLabel(@"Connect to MIDI sources (click to toggle):", pad, y, 400)];
    y -= 6;

    NSScrollView* scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(pad, 12, W - 2 * pad, y - 12)];
    scrollView.hasVerticalScroller = YES;
    scrollView.autohidesScrollers = YES;
    scrollView.borderType = NSBezelBorder;

    _midiTableView = [[NSTableView alloc] initWithFrame:scrollView.bounds];
    NSTableColumn* checkCol = [[NSTableColumn alloc] initWithIdentifier:@"connected"];
    checkCol.title = @""; checkCol.width = 30; checkCol.minWidth = 30; checkCol.maxWidth = 30;
    [_midiTableView addTableColumn:checkCol];
    NSTableColumn* nameCol = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    nameCol.title = @"Source"; nameCol.width = W - 2 * pad - 50;
    [_midiTableView addTableColumn:nameCol];

    _midiTableView.dataSource = self;
    _midiTableView.delegate = self;
    _midiTableView.headerView = nil;
    _midiTableView.rowHeight = 22;
    _midiTableView.target = self;
    _midiTableView.action = @selector(midiTableClicked:);
    scrollView.documentView = _midiTableView;
    [c addSubview:scrollView];

    return self;
}

// ── Show / refresh ──

- (void)showWindow:(id)sender {
    [self refreshAll];
    [super showWindow:sender];
    [self.window center];
}

- (void)refreshAll {
    [self refreshParams];
    [self refreshAudioInfo];
    [self refreshMIDISources];
    [self refreshModelName];
    BOOL kbdMidi = [[NSUserDefaults standardUserDefaults] boolForKey:@"Confabulator_ComputerKeyboardMidi"];
    _computerKeyboardMidiCheckbox.state = kbdMidi ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)computerKeyboardMidiChanged:(NSButton*)sender {
    BOOL enabled = (sender.state == NSControlStateValueOn);
    [_appController setComputerKeyboardMidiEnabled:enabled];
}

- (void)refreshModelName {
    NSString* modelPath = [[NSUserDefaults standardUserDefaults] stringForKey:@"Confabulator_ModelPath"];
    _modelNameLabel.stringValue = modelPath ? modelPath.lastPathComponent : @"No model loaded";
}

- (void)refreshParams {
    ColliderAppController* ctrl = _appController;
    if (!ctrl) return;

    _temperatureSlider.doubleValue = [ctrl readParamFromEngine:0];
    _temperatureValue.stringValue = [NSString stringWithFormat:@"%.2f", _temperatureSlider.doubleValue];

    _topkSlider.doubleValue = [ctrl readParamFromEngine:1];
    _topkValue.stringValue = [NSString stringWithFormat:@"%d", (int)_topkSlider.doubleValue];



    _cfgMusicCoCaSlider.doubleValue = [ctrl readParamFromEngine:3];
    _cfgMusicCoCaValue.stringValue = [NSString stringWithFormat:@"%.2f", _cfgMusicCoCaSlider.doubleValue];

    _cfgNotesSlider.doubleValue = [ctrl readParamFromEngine:4];
    _cfgNotesValue.stringValue = [NSString stringWithFormat:@"%.2f", _cfgNotesSlider.doubleValue];

    _cfgDrumsSlider.doubleValue = [ctrl readParamFromEngine:48];
    _cfgDrumsValue.stringValue = [NSString stringWithFormat:@"%.2f", _cfgDrumsSlider.doubleValue];

    _unmaskWidthSlider.doubleValue = [ctrl readParamFromEngine:7];
    _unmaskWidthValue.stringValue = [NSString stringWithFormat:@"%d", (int)_unmaskWidthSlider.doubleValue];

    _volumeSlider.doubleValue = [ctrl readParamFromEngine:5];
    _volumeValue.stringValue = [NSString stringWithFormat:@"%.1f", _volumeSlider.doubleValue];

    float bufVal = [ctrl readParamFromEngine:8];
    [_bufferSizePopup selectItemAtIndex:(bufVal < 0.5 ? 0 : (bufVal < 1.5 ? 1 : 2))];

    _muteCheckbox.state = ([ctrl readParamFromEngine:6] > 0.5) ? NSControlStateValueOn : NSControlStateValueOff;
    _drumModeCheckbox.state = ([ctrl readParamFromEngine:39] > 0.5) ? NSControlStateValueOn : NSControlStateValueOff;
}

// ── Slider / control actions ──

- (void)temperatureChanged:(NSSlider*)sender {
    _temperatureValue.stringValue = [NSString stringWithFormat:@"%.2f", sender.doubleValue];
    [_appController applyParamToEngine:0 value:(float)sender.doubleValue];
}
- (void)topkChanged:(NSSlider*)sender {
    int v = (int)sender.doubleValue;
    _topkValue.stringValue = [NSString stringWithFormat:@"%d", v];
    [_appController applyParamToEngine:1 value:(float)v];
}

- (void)cfgMusicCoCaChanged:(NSSlider*)sender {
    _cfgMusicCoCaValue.stringValue = [NSString stringWithFormat:@"%.2f", sender.doubleValue];
    [_appController applyParamToEngine:3 value:(float)sender.doubleValue];
}
- (void)cfgNotesChanged:(NSSlider*)sender {
    _cfgNotesValue.stringValue = [NSString stringWithFormat:@"%.2f", sender.doubleValue];
    [_appController applyParamToEngine:4 value:(float)sender.doubleValue];
}
- (void)cfgDrumsChanged:(NSSlider*)sender {
    _cfgDrumsValue.stringValue = [NSString stringWithFormat:@"%.2f", sender.doubleValue];
    [_appController applyParamToEngine:48 value:(float)sender.doubleValue];
}
- (void)unmaskWidthChanged:(NSSlider*)sender {
    int v = (int)sender.doubleValue;
    _unmaskWidthValue.stringValue = [NSString stringWithFormat:@"%d", v];
    [_appController applyParamToEngine:7 value:(float)v];
}
- (void)volumeChanged:(NSSlider*)sender {
    _volumeValue.stringValue = [NSString stringWithFormat:@"%.1f", sender.doubleValue];
    [_appController applyParamToEngine:5 value:(float)sender.doubleValue];
}
- (void)bufferSizeChanged:(NSPopUpButton*)sender {
    [_appController applyParamToEngine:8 value:(float)sender.indexOfSelectedItem];
}
- (void)muteChanged:(NSButton*)sender {
    [_appController applyParamToEngine:6 value:(sender.state == NSControlStateValueOn) ? 1.0f : 0.0f];
}
- (void)drumModeChanged:(NSButton*)sender {
    [_appController applyParamToEngine:39 value:(sender.state == NSControlStateValueOn) ? 1.0f : 0.0f];
}


- (void)loadModelClicked:(id)sender {
    [_appController handleLoadModel];
    // Refresh model name after a short delay (loading is async)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refreshModelName];
    });
}

- (void)resetDefaults:(id)sender {
    [MagentaSettings resetDefaultsOnEngine:_appController.engine
                              prefixString:@"Confabulator"
                                  cfgNotes:kColliderDefaultCfgNotes
                              cfgMusicCoCa:kColliderDefaultCfgMusicCoCa];
    [self refreshParams];
}

// ── Audio info ──

- (void)refreshAudioInfo {
    if (!_audioEngine) return;
    AVAudioFormat* outputFormat = [_audioEngine.outputNode outputFormatForBus:0];
    double sampleRate = outputFormat.sampleRate;

    AudioDeviceID deviceID = 0;
    UInt32 propSize = sizeof(deviceID);
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &propSize, &deviceID);

    NSString* deviceName = @"Unknown";
    if (deviceID != 0) {
        CFStringRef cfName = NULL;
        propSize = sizeof(cfName);
        AudioObjectPropertyAddress nameAddr = {
            kAudioDevicePropertyDeviceNameCFString,
            kAudioObjectPropertyScopeOutput,
            kAudioObjectPropertyElementMain
        };
        if (AudioObjectGetPropertyData(deviceID, &nameAddr, 0, NULL, &propSize, &cfName) == noErr && cfName) {
            deviceName = (__bridge_transfer NSString*)cfName;
        }
    }

    UInt32 bufferFrames = 0;
    propSize = sizeof(bufferFrames);
    AudioObjectPropertyAddress bufAddr = {
        kAudioDevicePropertyBufferFrameSize,
        kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    if (deviceID != 0) {
        AudioObjectGetPropertyData(deviceID, &bufAddr, 0, NULL, &propSize, &bufferFrames);
    }

    _audioDeviceLabel.stringValue = deviceName;
    _audioSampleRateLabel.stringValue = [NSString stringWithFormat:@"%.0f Hz (engine: 48000 Hz)", sampleRate];
    _audioBufferSizeLabel.stringValue = [NSString stringWithFormat:@"%u frames", (unsigned)bufferFrames];
}

// ── MIDI sources ──

- (void)refreshMIDISources {
    [_midiSources removeAllObjects];
    ItemCount sourceCount = MIDIGetNumberOfSources();
    for (ItemCount i = 0; i < sourceCount; ++i) {
        MIDIEndpointRef src = MIDIGetSource(i);
        CFStringRef cfName = NULL;
        MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &cfName);
        NSString* name = cfName ? (__bridge_transfer NSString*)cfName : @"Unknown MIDI Source";
        BOOL connected = [_connectedSources containsObject:@((uint32_t)src)];
        [_midiSources addObject:@{ @"name": name, @"endpoint": @((uint32_t)src), @"connected": @(connected) }];
    }
    [_midiTableView reloadData];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return (NSInteger)_midiSources.count; }

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (row >= (NSInteger)_midiSources.count) return nil;
    NSDictionary* source = _midiSources[(NSUInteger)row];
    if ([tableColumn.identifier isEqualToString:@"connected"]) {
        NSTextField* cell = [tableView makeViewWithIdentifier:@"checkCell" owner:self];
        if (!cell) { cell = [NSTextField labelWithString:@""]; cell.identifier = @"checkCell"; cell.alignment = NSTextAlignmentCenter; }
        cell.stringValue = [source[@"connected"] boolValue] ? @"\u2713" : @"";
        cell.font = [NSFont systemFontOfSize:14];
        return cell;
    } else {
        NSTextField* cell = [tableView makeViewWithIdentifier:@"nameCell" owner:self];
        if (!cell) { cell = [NSTextField labelWithString:@""]; cell.identifier = @"nameCell"; cell.bordered = NO; cell.editable = NO; cell.drawsBackground = NO; }
        cell.stringValue = source[@"name"];
        cell.font = [NSFont systemFontOfSize:12];
        return cell;
    }
}

- (void)midiTableClicked:(id)sender {
    NSInteger row = _midiTableView.clickedRow;
    if (row < 0 || row >= (NSInteger)_midiSources.count) return;
    NSDictionary* source = _midiSources[(NSUInteger)row];
    MIDIEndpointRef endpoint = (MIDIEndpointRef)[source[@"endpoint"] unsignedIntValue];
    BOOL wasConnected = [source[@"connected"] boolValue];
    if (wasConnected) {
        if (MIDIPortDisconnectSource(_midiInputPort, endpoint) == noErr)
            [_connectedSources removeObject:@((uint32_t)endpoint)];
    } else {
        if (MIDIPortConnectSource(_midiInputPort, endpoint, NULL) == noErr)
            [_connectedSources addObject:@((uint32_t)endpoint)];
    }
    [self refreshMIDISources];
}
@end

// ─── AppDelegate ─────────────────────────────────────────────────────────────

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AppDelegate {
    RealtimeRunner _engine;
    ColliderSharedState _sharedState;
    ConfabulatorDsp _dsp;
    AVAudioEngine* _audioEngine;
    AVAudioSourceNode* _sourceNode;
    MIDIClientRef _midiClient;
    MIDIPortRef _midiInputPort;
    MIDIEndpointRef _midiVirtualDest;
    NSWindow* _window;
    ColliderAppController* _controller;
    ColliderSettingsController* _settingsController;
    BOOL _isPlaying;
    NSMenuItem* _playStopMenuItem;
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    // Initialize ML assets from ~/Documents/Magenta/magenta-rt-v2/resources (centralized path) or saved custom folder.
    // Model files should be placed in ~/Documents/Magenta/magenta-rt-v2/models/.
    NSString *customResources = [[NSUserDefaults standardUserDefaults] stringForKey:@"MagentaRT_CustomResourcesPath"];
    std::string resources = customResources ? customResources.UTF8String : magentart::paths::get_resources_dir();
    if (!_engine.init_assets(resources.c_str())) {
        NSLog(@"CONFABULATOR: Failed to load static assets from %s", resources.c_str());
    }

    _controller = [[ColliderAppController alloc] init];
    _controller.engine = &_engine;
    _controller.sharedState = &_sharedState;

    // Restore saved parameters immediately so the engine has them from start
    [_controller restoreSavedParams];

    // Start bypassed — user must press Play
    _engine.set_bypass(true);
    _engine.set_cfg_musiccoca(kColliderDefaultCfgMusicCoCa);
    _engine.set_cfg_notes(kColliderDefaultCfgNotes);

    NSRect frame = NSMakeRect(0, 0, 1280, 760);
    _window = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:NSWindowStyleMaskTitled |
                                                    NSWindowStyleMaskClosable |
                                                    NSWindowStyleMaskMiniaturizable |
                                                    NSWindowStyleMaskResizable
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.title = @"CONFABULATOR";
    _window.restorable = NO;
    _window.contentMinSize = NSMakeSize(980, 620);
    _window.contentViewController = _controller;
    [_window center];
    [_window makeKeyAndOrderFront:nil];

    [self setupAudioEngine];
    [self setupMIDI];
    [self setupMenuBar];

    _settingsController = [[ColliderSettingsController alloc] init];
    _settingsController.midiClient = _midiClient;
    _settingsController.midiInputPort = _midiInputPort;
    _settingsController.audioEngine = _audioEngine;
    _settingsController.appController = _controller;

    [self autoLoadModel];
}

// ─── AVAudioEngine ───────────────────────────────────────────────────────────

- (void)setupAudioEngine {
    _audioEngine = [[AVAudioEngine alloc] init];
    AVAudioFormat* format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000.0 channels:2];

    RealtimeRunner* engine = &_engine;
    ColliderSharedState* shared = &_sharedState;
    ConfabulatorDsp* dsp = &_dsp;

    _sourceNode = [[AVAudioSourceNode alloc]
        initWithFormat:format
        renderBlock:^OSStatus(BOOL* isSilence, const AudioTimeStamp* timestamp,
                              AVAudioFrameCount frameCount, AudioBufferList* outputData) {
        float* outL = (float*)outputData->mBuffers[0].mData;
        float* outR = (outputData->mNumberBuffers > 1)
                      ? (float*)outputData->mBuffers[1].mData : outL;

        if (!engine->is_loaded()) {
            memset(outL, 0, frameCount * sizeof(float));
            if (outputData->mNumberBuffers > 1) memset(outR, 0, frameCount * sizeof(float));
            *isSilence = YES;
            return noErr;
        }

        engine->read_audio_stereo(outL, outR, frameCount, false);
        dsp->process(shared, outL, outR, (int)frameCount);
        shared->pushAudioSamples(outL, outR, frameCount);
        return noErr;
    }];

    [_audioEngine attachNode:_sourceNode];
    [_audioEngine connect:_sourceNode to:_audioEngine.mainMixerNode format:format];

    NSError* error = nil;
    if (![_audioEngine startAndReturnError:&error]) {
        NSLog(@"CONFABULATOR: AVAudioEngine failed to start: %@", error);
    }
}

// ─── CoreMIDI ────────────────────────────────────────────────────────────────

- (void)setupMIDI {
    RealtimeRunner* engine = &_engine;
    ColliderSharedState* shared = &_sharedState;

    OSStatus status = MIDIClientCreateWithBlock(
        CFSTR("CONFABULATOR"),
        &_midiClient,
        ^(const MIDINotification* notification) {
            if (notification->messageID == kMIDIMsgSetupChanged) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self->_settingsController refreshMIDISources];
                });
            }
        }
    );
    if (status != noErr) { NSLog(@"CONFABULATOR: MIDIClientCreate failed: %d", (int)status); return; }

    status = MIDIInputPortCreateWithProtocol(
        _midiClient, CFSTR("CONFABULATOR In"), kMIDIProtocol_1_0, &_midiInputPort,
        ^(const MIDIEventList* evtList, void* srcConnRefCon) {
            const MIDIEventPacket* pkt = &evtList->packet[0];
            for (UInt32 i = 0; i < evtList->numPackets; ++i) {
                for (UInt32 w = 0; w < pkt->wordCount; ++w) {
                    uint32_t word = pkt->words[w];
                    uint8_t msgType = (word >> 28) & 0xF;
                    if (msgType == 0x2) {
                        uint8_t statusByte = (word >> 16) & 0xFF;
                        uint8_t statusNibble = statusByte & 0xF0;
                        uint8_t note = (word >> 8) & 0x7F;
                        uint8_t velocity = word & 0x7F;
                        if (statusNibble == 0x90 && velocity > 0) {
                            engine->set_note_on(note);
                            shared->noteOn(note);
                        } else if (statusNibble == 0x80 || (statusNibble == 0x90 && velocity == 0)) {
                            engine->set_note_off(note);
                            shared->noteOff(note);
                        }
                    }
                }
                pkt = MIDIEventPacketNext(pkt);
            }
        }
    );
    if (status != noErr) { NSLog(@"CONFABULATOR: MIDIInputPortCreate failed: %d", (int)status); return; }

    status = MIDIDestinationCreateWithProtocol(
        _midiClient, CFSTR("CONFABULATOR Input"), kMIDIProtocol_1_0, &_midiVirtualDest,
        ^(const MIDIEventList* evtList, void* srcConnRefCon) {
            const MIDIEventPacket* pkt = &evtList->packet[0];
            for (UInt32 i = 0; i < evtList->numPackets; ++i) {
                for (UInt32 w = 0; w < pkt->wordCount; ++w) {
                    uint32_t word = pkt->words[w];
                    uint8_t msgType = (word >> 28) & 0xF;
                    if (msgType == 0x2) {
                        uint8_t statusByte = (word >> 16) & 0xFF;
                        uint8_t statusNibble = statusByte & 0xF0;
                        uint8_t note = (word >> 8) & 0x7F;
                        uint8_t velocity = word & 0x7F;
                        if (statusNibble == 0x90 && velocity > 0) {
                            engine->set_note_on(note);
                            shared->noteOn(note);
                        } else if (statusNibble == 0x80 || (statusNibble == 0x90 && velocity == 0)) {
                            engine->set_note_off(note);
                            shared->noteOff(note);
                        }
                    }
                }
                pkt = MIDIEventPacketNext(pkt);
            }
        }
    );
    if (status != noErr) {
        NSLog(@"CONFABULATOR: MIDIDestinationCreate failed: %d", (int)status);
    }
}

// ─── Menu bar ────────────────────────────────────────────────────────────────

- (void)setupMenuBar {
    NSMenu* menuBar = [[NSMenu alloc] init];

    NSMenuItem* appMenuItem = [[NSMenuItem alloc] init];
    NSMenu* appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"About CONFABULATOR" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Settings..." action:@selector(menuShowSettings:) keyEquivalent:@","];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit CONFABULATOR" action:@selector(terminate:) keyEquivalent:@"q"];
    appMenuItem.submenu = appMenu;
    [menuBar addItem:appMenuItem];

    NSMenuItem* fileMenuItem = [[NSMenuItem alloc] init];
    NSMenu* fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu addItemWithTitle:@"Load Model..." action:@selector(menuLoadModel:) keyEquivalent:@"o"];
    fileMenuItem.submenu = fileMenu;
    [menuBar addItem:fileMenuItem];

    NSMenuItem* editMenuItem = [[NSMenuItem alloc] init];
    NSMenu* editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    editMenuItem.submenu = editMenu;
    [menuBar addItem:editMenuItem];

    NSMenuItem* transportMenuItem = [[NSMenuItem alloc] init];
    NSMenu* transportMenu = [[NSMenu alloc] initWithTitle:@"Transport"];
    _playStopMenuItem = [transportMenu addItemWithTitle:@"Play"
                                                  action:@selector(menuTogglePlayStop:)
                                           keyEquivalent:@" "];
    _isPlaying = NO;
    transportMenuItem.submenu = transportMenu;
    [menuBar addItem:transportMenuItem];

    [NSApp setMainMenu:menuBar];
}

- (void)menuTogglePlayStop:(id)sender {
    if (_isPlaying) {
        _engine.set_bypass(true);
        _isPlaying = NO;
        _playStopMenuItem.title = @"Play";
    } else {
        _engine.set_bypass(false);
        _engine.trigger_reset();
        _isPlaying = YES;
        _playStopMenuItem.title = @"Pause";
    }
    [_controller sendPlayState:_isPlaying];
}

- (void)menuShowSettings:(id)sender {
    if (_controller) {
        [_controller showReactSettings];
    }
}

- (void)menuLoadModel:(id)sender {
    [_controller handleLoadModel];
}

// ─── Auto-load model ─────────────────────────────────────────────────────────

- (void)autoLoadModel {
    NSString* modelPath = [[NSUserDefaults standardUserDefaults] stringForKey:@"Confabulator_ModelPath"];
    if (!modelPath) return;

    if (![[NSFileManager defaultManager] fileExistsAtPath:modelPath]) return;

    NSLog(@"CONFABULATOR: Auto-loading model from %@", modelPath);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL success = self->_engine.load_model(modelPath.UTF8String);
        if (success) {
            NSLog(@"CONFABULATOR: Model loaded successfully.");

            NSString* parentDir = [modelPath stringByDeletingLastPathComponent];
            NSString* corpusPath = [parentDir stringByAppendingPathComponent:@"corpus.safetensors"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:corpusPath]) {
                self->_engine.load_pca_file(corpusPath.UTF8String);
            }

            [self->_controller restoreSavedParams];

            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_controller notifyModelLoaded:modelPath.lastPathComponent];
            });
        } else {
            NSLog(@"CONFABULATOR: Failed to auto-load model from %@", modelPath);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_controller sendStateUpdate:@{@"modelName": @"No model loaded"}];
            });
        }
    });
}

// ─── Lifecycle ───────────────────────────────────────────────────────────────

- (void)applicationWillTerminate:(NSNotification*)notification {
    _engine.stop();
    _engine.unload();
    [_audioEngine stop];
    if (_midiVirtualDest) MIDIEndpointDispose(_midiVirtualDest);
    if (_midiInputPort) MIDIPortDispose(_midiInputPort);
    if (_midiClient) MIDIClientDispose(_midiClient);
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender { return YES; }
- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app { return YES; }

@end

// ─── main ────────────────────────────────────────────────────────────────────

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        AppDelegate* delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
