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

#pragma once
#import <Cocoa/Cocoa.h>
#include <magentart/realtime_runner.h>
#include <atomic>
#include <algorithm>
#include <vector>

using magentart::core::RealtimeRunner;

// Shared state between audio/MIDI threads and the UI controller
struct ColliderSharedState {
    static constexpr int kSampleRate = 48000;
    static constexpr int kMinRollingSeconds = 10;
    static constexpr int kDefaultRollingSeconds = 30;
    static constexpr int kMaxRollingSeconds = 120;
    static constexpr int kMaxRetroLiveSeconds = 10 * 60;
    static constexpr std::size_t kRollingCapacitySamples =
        static_cast<std::size_t>(kSampleRate) * kMaxRollingSeconds;
    static constexpr std::size_t kMaxRetroLiveSamples =
        static_cast<std::size_t>(kSampleRate) * kMaxRetroLiveSeconds;

    std::atomic<bool> midiNotes[128] = {};

    std::atomic<float> fxWet{0.0f};
    std::atomic<float> fxDrive{0.0f};
    std::atomic<float> fxFold{0.0f};
    std::atomic<float> fxCrush{0.0f};
    std::atomic<float> fxRing{0.0f};
    std::atomic<float> fxComb{0.0f};
    std::atomic<float> fxBody{0.0f};
    std::atomic<float> fxSmear{0.0f};
    std::atomic<float> fxStutter{0.0f};
    std::atomic<float> fxPitch{0.5f};
    std::atomic<float> fxHarmonics{0.0f};
    std::atomic<float> fxNoise{0.0f};
    std::atomic<float> rvqForce{0.0f};
    std::atomic<float> rvqBreathe{0.0f};
    std::atomic<float> rvqMemory{0.0f};
    std::atomic<float> rvqCoarse{0.0f};
    std::atomic<float> rvqFine{0.0f};
    std::atomic<float> rvqSweep{0.0f};
    std::atomic<float> rvqHold{0.0f};
    std::atomic<float> rvqInvert{0.0f};
    std::atomic<float> rvqJitter{0.0f};
    std::atomic<float> rvqStride{0.0f};

    static constexpr int VIZ_BUF_SIZE = 8192;
    float vizRing[VIZ_BUF_SIZE] = {};
    std::atomic<int> vizHead{0};

    std::vector<float> rollingL;
    std::vector<float> rollingR;
    std::atomic<std::size_t> rollingWriteHead{0};
    std::atomic<std::size_t> rollingFilledSamples{0};
    std::atomic<int> rollingWindowSeconds{kDefaultRollingSeconds};

    std::atomic<bool> retroRecording{false};
    std::vector<float> retroSeedL;
    std::vector<float> retroSeedR;
    std::vector<float> retroLiveL;
    std::vector<float> retroLiveR;
    std::atomic<std::size_t> retroLiveSamples{0};
    std::size_t retroSeedSamples = 0;

    ColliderSharedState()
        : rollingL(kRollingCapacitySamples, 0.0f),
          rollingR(kRollingCapacitySamples, 0.0f),
          retroLiveL(kMaxRetroLiveSamples, 0.0f),
          retroLiveR(kMaxRetroLiveSamples, 0.0f) {}

    void pushAudioSamples(const float* left, const float* right, int count) {
        int h = vizHead.load(std::memory_order_relaxed);
        for (int i = 0; i < count; i++) {
            vizRing[h] = (left[i] + right[i]) * 0.5f;
            h = (h + 1) % VIZ_BUF_SIZE;
        }
        vizHead.store(h, std::memory_order_release);

        std::size_t write = rollingWriteHead.load(std::memory_order_relaxed);
        for (int i = 0; i < count; i++) {
            rollingL[write] = left[i];
            rollingR[write] = right[i];
            write = (write + 1) % kRollingCapacitySamples;
        }
        rollingWriteHead.store(write, std::memory_order_release);

        std::size_t filled = rollingFilledSamples.load(std::memory_order_relaxed);
        filled = std::min(kRollingCapacitySamples, filled + static_cast<std::size_t>(count));
        rollingFilledSamples.store(filled, std::memory_order_release);

        if (retroRecording.load(std::memory_order_relaxed)) {
            std::size_t start = retroLiveSamples.load(std::memory_order_relaxed);
            std::size_t writable = std::min<std::size_t>(
                static_cast<std::size_t>(count),
                start < kMaxRetroLiveSamples ? kMaxRetroLiveSamples - start : 0);
            for (std::size_t i = 0; i < writable; i++) {
                retroLiveL[start + i] = left[i];
                retroLiveR[start + i] = right[i];
            }
            retroLiveSamples.store(start + writable, std::memory_order_release);
        }
    }

    void noteOn(uint8_t note) { if (note < 128) midiNotes[note].store(true, std::memory_order_relaxed); }
    void noteOff(uint8_t note) { if (note < 128) midiNotes[note].store(false, std::memory_order_relaxed); }

    void setRollingSeconds(int seconds) {
        rollingWindowSeconds.store(
            std::max(kMinRollingSeconds, std::min(kMaxRollingSeconds, seconds)),
            std::memory_order_relaxed);
    }

    int getRollingSeconds() const {
        return rollingWindowSeconds.load(std::memory_order_relaxed);
    }

    std::size_t getAvailableRollingSamples() const {
        std::size_t filled = rollingFilledSamples.load(std::memory_order_acquire);
        std::size_t requested =
            static_cast<std::size_t>(getRollingSeconds()) * kSampleRate;
        return std::min(filled, requested);
    }

    bool copyLastSeconds(int seconds, std::vector<float>& outL, std::vector<float>& outR) const {
        int clampedSeconds = std::max(1, std::min(kMaxRollingSeconds, seconds));
        std::size_t filled = rollingFilledSamples.load(std::memory_order_acquire);
        std::size_t requested = static_cast<std::size_t>(clampedSeconds) * kSampleRate;
        std::size_t samples = std::min(filled, requested);
        if (samples == 0) return false;

        outL.resize(samples);
        outR.resize(samples);
        std::size_t write = rollingWriteHead.load(std::memory_order_acquire);
        std::size_t start = (write + kRollingCapacitySamples - samples) % kRollingCapacitySamples;
        for (std::size_t i = 0; i < samples; i++) {
            std::size_t idx = (start + i) % kRollingCapacitySamples;
            outL[i] = rollingL[idx];
            outR[i] = rollingR[idx];
        }
        return true;
    }

    bool startRetroRecording(int seconds) {
        std::vector<float> seedL;
        std::vector<float> seedR;
        copyLastSeconds(seconds, seedL, seedR);
        retroRecording.store(false, std::memory_order_release);
        retroSeedL = std::move(seedL);
        retroSeedR = std::move(seedR);
        retroSeedSamples = std::min(retroSeedL.size(), retroSeedR.size());
        retroLiveSamples.store(0, std::memory_order_relaxed);
        retroRecording.store(true, std::memory_order_release);
        return true;
    }

    bool stopRetroRecording(std::vector<float>& outL, std::vector<float>& outR) {
        retroRecording.store(false, std::memory_order_release);
        std::size_t live = retroLiveSamples.load(std::memory_order_acquire);
        std::size_t seed = retroSeedSamples;
        std::size_t total = seed + live;
        if (total == 0) return false;

        outL.resize(total);
        outR.resize(total);
        if (seed > 0) {
            std::copy(retroSeedL.begin(), retroSeedL.begin() + seed, outL.begin());
            std::copy(retroSeedR.begin(), retroSeedR.begin() + seed, outR.begin());
        }
        if (live > 0) {
            std::copy(retroLiveL.begin(), retroLiveL.begin() + live, outL.begin() + seed);
            std::copy(retroLiveR.begin(), retroLiveR.begin() + live, outR.begin() + seed);
        }
        retroSeedL.clear();
        retroSeedR.clear();
        retroSeedSamples = 0;
        retroLiveSamples.store(0, std::memory_order_relaxed);
        return true;
    }

    double getRetroRecordingSeconds() const {
        std::size_t live = retroLiveSamples.load(std::memory_order_acquire);
        return static_cast<double>(retroSeedSamples + live) / static_cast<double>(kSampleRate);
    }
};

@interface ColliderAppController : NSViewController
@property (nonatomic, assign) RealtimeRunner* engine;
@property (nonatomic, assign) ColliderSharedState* sharedState;
- (void)notifyModelLoaded:(NSString*)modelName;
- (void)sendStateUpdate:(NSDictionary*)state;
- (void)restoreSavedParams;
- (void)startAgentServerIfNeeded;
- (void)handleLoadModel;
- (void)showReactSettings;
- (void)sendPlayState:(BOOL)playing;
// Param bridging — also used by settings window
- (void)applyParamToEngine:(int)address value:(float)value;
- (float)readParamFromEngine:(int)address;
// Computer-keyboard-as-MIDI (toggled from settings window)
- (void)setComputerKeyboardMidiEnabled:(BOOL)enabled;
@end
