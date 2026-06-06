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

// Collider view controller — hosts the Collider React UI in a WKWebView.
// Simplified from MagentaRTAppController: single prompt, MIDI/waveform visualization.

#import "ColliderAppController.h"
#import <WebKit/WebKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <AudioToolbox/AudioToolbox.h>
#import "MagentaModelManager.h"
#import "MagentaModelDownloader.h"
#import "MagentaSettings.h"
#include "magenta_paths.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <errno.h>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <utility>

using magentart::core::RealtimeRunner;
using magentart::core::EngineMetrics;
using magentart::core::kMusicCoCaEmbeddingDim;

// ─── TEMP Dev server probe ────────────────────────────────────────────────────────

static const int kDevServerPort = 62419;
static const int kConfabulatorAgentPort = 47873;

@class ColliderAppController;

@interface ColliderAppController (AgentSocket)
- (void)handleAgentSocketCommand:(NSDictionary*)command;
- (NSArray<NSDictionary*>*)agentWelcomeMessages;
@end

static BOOL confabWriteAll(int fd, NSData* data) {
    const uint8_t* bytes = static_cast<const uint8_t*>(data.bytes);
    NSUInteger remaining = data.length;
    while (remaining > 0) {
        ssize_t written = write(fd, bytes, remaining);
        if (written < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (written == 0) return NO;
        bytes += written;
        remaining -= static_cast<NSUInteger>(written);
    }
    return YES;
}

@interface ConfabulatorAgentServer : NSObject
- (instancetype)initWithController:(ColliderAppController*)controller;
- (void)start;
- (void)stop;
- (void)broadcastJSONObject:(NSDictionary*)object;
@end

@implementation ConfabulatorAgentServer {
    __weak ColliderAppController* _controller;
    dispatch_queue_t _queue;
    NSMutableSet<NSNumber*>* _clients;
    int _serverSocket;
    std::atomic<bool> _running;
}

- (instancetype)initWithController:(ColliderAppController*)controller {
    self = [super init];
    if (self) {
        _controller = controller;
        _queue = dispatch_queue_create("confabulator.agent.socket", DISPATCH_QUEUE_CONCURRENT);
        _clients = [NSMutableSet set];
        _serverSocket = -1;
        _running.store(false, std::memory_order_relaxed);
    }
    return self;
}

- (void)start {
    if (_running.exchange(true, std::memory_order_acq_rel)) return;

    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        _running.store(false, std::memory_order_release);
        NSLog(@"CONFABULATOR Agent: socket() failed: %s", strerror(errno));
        return;
    }

    int reuse = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kConfabulatorAgentPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (bind(sock, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr)) != 0 ||
        listen(sock, 8) != 0) {
        NSLog(@"CONFABULATOR Agent: could not listen on 127.0.0.1:%d (%s)",
              kConfabulatorAgentPort, strerror(errno));
        close(sock);
        _running.store(false, std::memory_order_release);
        return;
    }

    _serverSocket = sock;
    NSLog(@"CONFABULATOR Agent: listening on 127.0.0.1:%d", kConfabulatorAgentPort);

    dispatch_async(_queue, ^{
        while (self->_running.load(std::memory_order_acquire)) {
            struct sockaddr_in clientAddr = {};
            socklen_t clientLen = sizeof(clientAddr);
            int client = accept(self->_serverSocket,
                                reinterpret_cast<struct sockaddr*>(&clientAddr),
                                &clientLen);
            if (client < 0) {
                if (errno == EINTR) continue;
                if (self->_running.load(std::memory_order_acquire)) {
                    NSLog(@"CONFABULATOR Agent: accept() failed: %s", strerror(errno));
                }
                break;
            }

            @synchronized (self) {
                [self->_clients addObject:@(client)];
            }

            [self sendJSONObject:@{
                @"type": @"hello",
                @"schema_version": @1,
                @"protocol": @"confabulator-agent-jsonl",
                @"port": @(kConfabulatorAgentPort),
                @"commands": @[
                    @"setParam", @"setCore", @"setFx", @"setDamage", @"setRvq",
                    @"setPerformance", @"setTextLab", @"movePrompt", @"moveListener",
                    @"setPromptText", @"selectPrompt", @"selectEmbedding", @"setEmbeddings",
                    @"randomCore", @"randomDamage", @"jolt", @"clean", @"macro",
                    @"recordStart", @"recordStop", @"captureLast", @"setRecordingWindow",
                    @"play", @"togglePlay", @"kick", @"loadRecipe"
                ]
            } toClient:client];

            ColliderAppController* controller = self->_controller;
            if (controller) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    for (NSDictionary* message in [controller agentWelcomeMessages]) {
                        [self sendJSONObject:message toClient:client];
                    }
                });
            }

            dispatch_async(self->_queue, ^{
                [self readClient:client];
            });
        }
    });
}

- (void)stop {
    if (!_running.exchange(false, std::memory_order_acq_rel)) return;
    if (_serverSocket >= 0) {
        close(_serverSocket);
        _serverSocket = -1;
    }
    @synchronized (self) {
        for (NSNumber* clientNumber in _clients) {
            close(clientNumber.intValue);
        }
        [_clients removeAllObjects];
    }
}

- (void)dealloc {
    [self stop];
}

- (void)sendJSONObject:(NSDictionary*)object toClient:(int)client {
    if (!object) return;
    NSError* error = nil;
    NSData* json = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
    if (!json || error) return;
    NSMutableData* line = [NSMutableData dataWithData:json];
    const char newline = '\n';
    [line appendBytes:&newline length:1];
    if (!confabWriteAll(client, line)) {
        close(client);
        @synchronized (self) {
            [_clients removeObject:@(client)];
        }
    }
}

- (void)broadcastJSONObject:(NSDictionary*)object {
    if (!object || !_running.load(std::memory_order_acquire)) return;
    dispatch_async(_queue, ^{
        NSArray<NSNumber*>* clients = nil;
        @synchronized (self) {
            clients = [self->_clients allObjects];
        }
        for (NSNumber* clientNumber in clients) {
            [self sendJSONObject:object toClient:clientNumber.intValue];
        }
    });
}

- (void)readClient:(int)client {
    NSMutableData* pending = [NSMutableData data];
    uint8_t chunk[4096];

    while (_running.load(std::memory_order_acquire)) {
        ssize_t count = read(client, chunk, sizeof(chunk));
        if (count < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (count == 0) break;

        [pending appendBytes:chunk length:static_cast<NSUInteger>(count)];
        while (pending.length > 0) {
            const char* bytes = static_cast<const char*>(pending.bytes);
            const void* found = memchr(bytes, '\n', pending.length);
            if (!found) break;

            NSUInteger lineLength = static_cast<const char*>(found) - bytes;
            NSData* line = [NSData dataWithBytes:bytes length:lineLength];
            NSData* remainder = [pending subdataWithRange:NSMakeRange(lineLength + 1, pending.length - lineLength - 1)];
            [pending setData:remainder];

            if (line.length == 0) continue;
            NSError* error = nil;
            id object = [NSJSONSerialization JSONObjectWithData:line options:0 error:&error];
            if (!error && [object isKindOfClass:[NSDictionary class]]) {
                ColliderAppController* controller = self->_controller;
                if (controller) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [controller handleAgentSocketCommand:(NSDictionary*)object];
                    });
                }
            } else {
                [self sendJSONObject:@{
                    @"type": @"error",
                    @"message": error.localizedDescription ?: @"Invalid JSON command."
                } toClient:client];
            }
        }
    }

    close(client);
    @synchronized (self) {
        [_clients removeObject:@(client)];
    }
}

@end

static BOOL isDevServerRunning(void) {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return NO;
    struct timeval tv = { .tv_sec = 0, .tv_usec = 100000 }; // 100ms
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    struct sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kDevServerPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    BOOL up = (connect(sock, (struct sockaddr*)&addr, sizeof(addr)) == 0);
    close(sock);
    return up;
}

static NSString* confabulatorISODateString(NSDate* date) {
    NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZZZZZ";
    return [formatter stringFromDate:date ?: [NSDate date]];
}

static NSString* confabulatorFileTimestamp(NSDate* date) {
    NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyyMMdd_HHmmss";
    return [formatter stringFromDate:date ?: [NSDate date]];
}

static NSString* confabulatorCaptureDirectory(void) {
    NSArray<NSURL*>* urls = [[NSFileManager defaultManager] URLsForDirectory:NSMusicDirectory
                                                                   inDomains:NSUserDomainMask];
    NSURL* base = urls.firstObject ?: [NSURL fileURLWithPath:NSHomeDirectory()];
    NSURL* dir = [base URLByAppendingPathComponent:@"CONFABULATOR Captures" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    return dir.path;
}

static NSString* confabulatorSafeModeName(NSString* mode) {
    NSString* raw = mode.length ? mode : @"capture";
    NSCharacterSet* allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"];
    NSMutableString* safe = [NSMutableString stringWithCapacity:raw.length];
    for (NSUInteger i = 0; i < raw.length; ++i) {
        unichar c = [raw characterAtIndex:i];
        [safe appendString:[allowed characterIsMember:c] ? [NSString stringWithCharacters:&c length:1] : @"-"];
    }
    return safe.lowercaseString;
}

static void confabWriteU16(std::ofstream& f, uint16_t value) {
    f.write(reinterpret_cast<const char*>(&value), sizeof(value));
}

static void confabWriteU32(std::ofstream& f, uint32_t value) {
    f.write(reinterpret_cast<const char*>(&value), sizeof(value));
}

static bool confabWriteFloat32Wav(NSString* path,
                                  const std::vector<float>& left,
                                  const std::vector<float>& right,
                                  int sampleRate) {
    const std::size_t frames = std::min(left.size(), right.size());
    if (frames == 0 || frames > (UINT32_MAX / (2 * sizeof(float)))) {
        return false;
    }

    const uint16_t channels = 2;
    const uint16_t bitsPerSample = 32;
    const uint16_t audioFormat = 3; // WAVE_FORMAT_IEEE_FLOAT
    const uint32_t byteRate = static_cast<uint32_t>(sampleRate * channels * sizeof(float));
    const uint16_t blockAlign = static_cast<uint16_t>(channels * sizeof(float));
    const uint32_t dataSize = static_cast<uint32_t>(frames * channels * sizeof(float));
    const uint32_t riffSize = 36 + dataSize;

    std::ofstream f(path.fileSystemRepresentation, std::ios::binary);
    if (!f) return false;

    f.write("RIFF", 4);
    confabWriteU32(f, riffSize);
    f.write("WAVE", 4);
    f.write("fmt ", 4);
    confabWriteU32(f, 16);
    confabWriteU16(f, audioFormat);
    confabWriteU16(f, channels);
    confabWriteU32(f, static_cast<uint32_t>(sampleRate));
    confabWriteU32(f, byteRate);
    confabWriteU16(f, blockAlign);
    confabWriteU16(f, bitsPerSample);
    f.write("data", 4);
    confabWriteU32(f, dataSize);

    std::vector<float> interleaved(frames * channels);
    for (std::size_t i = 0; i < frames; ++i) {
        interleaved[i * 2] = left[i];
        interleaved[i * 2 + 1] = right[i];
    }
    f.write(reinterpret_cast<const char*>(interleaved.data()),
            static_cast<std::streamsize>(interleaved.size() * sizeof(float)));
    return static_cast<bool>(f);
}

// ─── WKWebView subclass for keyboard shortcuts ──────────────────────────────

@interface ColliderWebView : WKWebView
@end

@implementation ColliderWebView
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if ([event modifierFlags] & NSEventModifierFlagCommand) {
        NSString *chars = [event charactersIgnoringModifiers];
        if ([chars isEqualToString:@"c"]) { [NSApp sendAction:@selector(copy:) to:nil from:self]; return YES; }
        else if ([chars isEqualToString:@"v"]) { [NSApp sendAction:@selector(paste:) to:nil from:self]; return YES; }
        else if ([chars isEqualToString:@"a"]) { [NSApp sendAction:@selector(selectAll:) to:nil from:self]; return YES; }
        else if ([chars isEqualToString:@"x"]) { [NSApp sendAction:@selector(cut:) to:nil from:self]; return YES; }
    }
    return [super performKeyEquivalent:event];
}
@end

// ─── Param helpers ───────────────────────────────────────────────────────────





// Addresses of params to persist across launches


// ─── View Controller ─────────────────────────────────────────────────────────

@interface ColliderAppController () <WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate>
- (void)handleSelectDownloadFolder;
- (void)handleListLocalModels;
- (void)handleSelectModel:(NSString*)modelName;
- (void)handleDeleteModel:(NSString*)modelName;
- (void)handleInitResources:(NSString*)modelName;
- (NSDictionary*)currentRecorderStateWithStatus:(NSString*)status
                                       filePath:(NSString*)filePath
                                    sidecarPath:(NSString*)sidecarPath
                                          error:(NSString*)error;
- (void)handleRecorderSetWindow:(NSDictionary*)body;
- (void)handleRecorderCaptureLast:(NSDictionary*)body;
- (void)handleRecorderStart:(NSDictionary*)body;
- (void)handleRecorderStop:(NSDictionary*)body;
- (void)handleAgentState:(NSDictionary*)body;
- (void)handleAgentCatalog:(NSDictionary*)body;
- (NSDictionary*)currentAudioFeatureState;
- (void)publishAgentPerformanceStateWithAudio:(NSDictionary*)audioFeatures
                                      metrics:(NSDictionary*)metrics;
- (void)setTransportPlaying:(BOOL)playing reset:(BOOL)reset;
@end

@implementation ColliderAppController {
    WKWebView* _webView;
    NSTimer* _metricsTimer;
    NSMutableDictionary* _lastParams;
    int _metricsTicks;
    ConfabulatorAgentServer* _agentServer;
    NSDictionary* _lastAgentUiState;
    NSDictionary* _lastAgentCatalog;
    float _agentLastRms;
    float _agentLastBrightness;

    NSString* _modelName;
    NSString* _currentPromptText;
    BOOL _isPlaying;
}

// ─── Parameter bridging ──────────────────────────────────────────────────────

- (void)applyParamToEngine:(int)address value:(float)value {
    [MagentaSettings applyParamToEngine:self.engine address:address value:value prefixString:@"Confabulator"];
}

- (void)restoreSavedParams {
    [MagentaSettings restoreSavedParams:self.engine prefixString:@"Confabulator"];
}

- (float)readParamFromEngine:(int)address {
    return [MagentaSettings readParamFromEngine:self.engine address:address];
}

- (void)startAgentServerIfNeeded {
    if (!_agentServer) {
        _agentServer = [[ConfabulatorAgentServer alloc] initWithController:self];
        [_agentServer start];
    }
    [self sendStateUpdate:@{@"agent": @{
        @"enabled": @YES,
        @"protocol": @"confabulator-agent-jsonl",
        @"host": @"127.0.0.1",
        @"port": @(kConfabulatorAgentPort)
    }}];
}

// ─── View lifecycle ──────────────────────────────────────────────────────────

- (void)loadView {
    NSView* view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 700, 505)];
    view.wantsLayer = YES;
    view.layer.backgroundColor = [NSColor blackColor].CGColor;
    self.view = view;
}

- (void)viewDidAppear {
    [super viewDidAppear];
    _isPlaying = NO;

    NSWindow* hostWindow = self.view.window;
    if (hostWindow) {
        NSScreen* screen = hostWindow.screen ?: [NSScreen mainScreen];
        NSRect visibleFrame = screen.visibleFrame;
        CGFloat targetWidth = std::min<CGFloat>(1280.0, visibleFrame.size.width * 0.92);
        CGFloat targetHeight = std::min<CGFloat>(860.0, visibleFrame.size.height * 0.9);
        hostWindow.minSize = NSMakeSize(std::min<CGFloat>(1040.0, targetWidth),
                                        std::min<CGFloat>(720.0, targetHeight));

        NSRect frame = hostWindow.frame;
        if (frame.size.width < targetWidth * 0.88 || frame.size.height < targetHeight * 0.82) {
            frame.size = NSMakeSize(targetWidth, targetHeight);
            frame.origin.x = NSMidX(visibleFrame) - targetWidth * 0.5;
            frame.origin.y = NSMidY(visibleFrame) - targetHeight * 0.5;
            [hostWindow setFrame:frame display:YES animate:NO];
        }
    }

    if (!_webView) {
        WKWebViewConfiguration* config = [[WKWebViewConfiguration alloc] init];
        [config.preferences setValue:@YES forKey:@"developerExtrasEnabled"];
        [config.preferences setValue:@YES forKey:@"allowFileAccessFromFileURLs"];
        @try { [config setValue:@YES forKey:@"allowUniversalAccessFromFileURLs"]; } @catch (NSException *e) { }

        NSString *js = @"window.onerror = function(msg, url, line, col, error) { window.webkit.messageHandlers.auHost.postMessage({type:'log', value:'JS Error: '+msg+ ' @ line '+line}); };"
                       @"var origLog = console.log; console.log = function(msg) { window.webkit.messageHandlers.auHost.postMessage({type:'log', value:''+msg}); origLog(msg); };";
        WKUserScript *script = [[WKUserScript alloc] initWithSource:js injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES];
        [config.userContentController addUserScript:script];
        [config.userContentController addScriptMessageHandler:self name:@"auHost"];

        _webView = [[ColliderWebView alloc] initWithFrame:self.view.bounds configuration:config];
        _webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _webView.navigationDelegate = self;
        _webView.UIDelegate = self;
        [_webView setValue:@(NO) forKey:@"drawsBackground"];
        [self.view addSubview:_webView];

        if (isDevServerRunning()) {
            NSLog(@"CONFABULATOR: Vite dev server detected on port %d — loading with HMR", kDevServerPort);
            [_webView loadRequest:[NSURLRequest requestWithURL:
                [NSURL URLWithString:[NSString stringWithFormat:@"http://localhost:%d", kDevServerPort]]]];
        } else {
            NSBundle* bundle = [NSBundle mainBundle];
            NSString* uiPath = [bundle pathForResource:@"index" ofType:@"html" inDirectory:@"collider_ui"];
            if (uiPath) {
                NSURL* url = [NSURL fileURLWithPath:uiPath];
                [_webView loadFileURL:url allowingReadAccessToURL:[url URLByDeletingLastPathComponent]];
            } else {
                NSLog(@"CONFABULATOR: collider_ui/index.html not found in bundle");
            }
        }
    }

    if (_metricsTimer) [_metricsTimer invalidate];
    _metricsTicks = 0;
    _lastParams = [NSMutableDictionary dictionary];

    _metricsTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/25.0
                                                    target:self
                                                  selector:@selector(updateMetrics)
                                                  userInfo:nil
                                                   repeats:YES];

    [self startAgentServerIfNeeded];
}

- (void)viewDidDisappear {
    [super viewDidDisappear];
    if (_metricsTimer) { [_metricsTimer invalidate]; _metricsTimer = nil; }
    if (_webView) {
        [_webView.configuration.userContentController removeScriptMessageHandlerForName:@"auHost"];
        [_webView removeFromSuperview];
        _webView = nil;
    }
}

// ─── Metrics polling (25 Hz) ─────────────────────────────────────────────────

- (void)updateMetrics {
    RealtimeRunner* engine = self.engine;
    ColliderSharedState* shared = self.sharedState;
    if (!engine) return;

    _metricsTicks++;
    NSMutableDictionary* stateUpdate = [NSMutableDictionary dictionary];

    // Send MIDI active notes every frame
    if (shared) {
        NSMutableArray* notes = [NSMutableArray array];
        for (int i = 0; i < 128; i++) {
            if (shared->midiNotes[i].load(std::memory_order_relaxed)) {
                [notes addObject:@(i)];
            }
        }
        stateUpdate[@"activeNotes"] = notes;
    }

    NSDictionary* audioFeatures = nil;
    NSDictionary* metricsState = nil;

    // Send audio level every frame (single scalar — negligible bridge cost)
    if (shared) {
        audioFeatures = [self currentAudioFeatureState];
        stateUpdate[@"audioLevel"] = audioFeatures[@"peak"] ?: @0;
        stateUpdate[@"audioFeatures"] = audioFeatures;
    }

    // Metrics every 5th tick (~5 Hz)
    if (_metricsTicks >= 5) {
        _metricsTicks = 0;
        EngineMetrics m = engine->get_metrics();

        metricsState = @{
            @"frameMs": @(m.transformer_ms),
            @"bufferAvail": @(m.buffer_available),
            @"bufferCap": @(m.buffer_capacity),
            @"droppedFrames": @(m.dropped_frames)
        };
        stateUpdate[@"metrics"] = metricsState;
        if (shared) {
            stateUpdate[@"recorder"] = [self currentRecorderStateWithStatus:nil
                                                                    filePath:nil
                                                                 sidecarPath:nil
                                                                       error:nil];
        }
    }

    // Params — send only changed values
    NSMutableDictionary* params = [NSMutableDictionary dictionary];
    int addresses[] = {0,1,3,4,5,6,7,8,9,32,33,34,35,36,37,38,39,47,48};
    for (int addr : addresses) {
        NSString* key = [MagentaSettings paramKeyForAddress:addr];
        if (!key) continue;
        float rawVal = [self readParamFromEngine:addr];
        NSNumber* val = [MagentaSettings paramIsBool:addr] ? @(rawVal > 0.5) : @(rawVal);
        NSNumber* lastVal = _lastParams[key];
        if (!lastVal || ![lastVal isEqualToNumber:val]) {
            params[key] = val;
            _lastParams[key] = val;
        }
    }
    if (params.count > 0) stateUpdate[@"params"] = params;

    if (stateUpdate.count > 0) [self sendStateUpdate:stateUpdate];
    if (audioFeatures && metricsState) {
        [self publishAgentPerformanceStateWithAudio:audioFeatures metrics:metricsState];
    }
}

// ─── State push to React ─────────────────────────────────────────────────────

- (void)sendStateUpdate:(NSDictionary*)state {
    if (!_webView) return;
    NSError* error = nil;
    NSData* jsonData = [NSJSONSerialization dataWithJSONObject:state options:0 error:&error];
    if (error) return;
    NSString* jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    NSString* script = [NSString stringWithFormat:@"if (window.updateState) { window.updateState(%@); }", jsonString];
    [_webView evaluateJavaScript:script completionHandler:nil];
}

- (void)sendPlayState:(BOOL)playing {
    _isPlaying = playing;
    [self sendStateUpdate:@{@"isPlaying": @(playing)}];
}

- (void)setTransportPlaying:(BOOL)playing reset:(BOOL)reset {
    if (!self.engine) return;
    if (playing == _isPlaying) {
        [self sendPlayState:_isPlaying];
        return;
    }
    self.engine->set_bypass(!playing);
    if (playing && reset) {
        self.engine->trigger_reset();
    }
    [self sendPlayState:playing];
}

- (NSDictionary*)currentFxState {
    ColliderSharedState* shared = self.sharedState;
    if (!shared) return @{};
    return @{
        @"wet": @(shared->fxWet.load(std::memory_order_relaxed)),
        @"drive": @(shared->fxDrive.load(std::memory_order_relaxed)),
        @"fold": @(shared->fxFold.load(std::memory_order_relaxed)),
        @"crush": @(shared->fxCrush.load(std::memory_order_relaxed)),
        @"ring": @(shared->fxRing.load(std::memory_order_relaxed)),
        @"comb": @(shared->fxComb.load(std::memory_order_relaxed)),
        @"body": @(shared->fxBody.load(std::memory_order_relaxed)),
        @"smear": @(shared->fxSmear.load(std::memory_order_relaxed)),
        @"stutter": @(shared->fxStutter.load(std::memory_order_relaxed)),
        @"pitch": @(shared->fxPitch.load(std::memory_order_relaxed)),
        @"harmonics": @(shared->fxHarmonics.load(std::memory_order_relaxed)),
        @"noise": @(shared->fxNoise.load(std::memory_order_relaxed)),
        @"rvqForce": @(shared->rvqForce.load(std::memory_order_relaxed)),
        @"rvqBreathe": @(shared->rvqBreathe.load(std::memory_order_relaxed)),
        @"rvqMemory": @(shared->rvqMemory.load(std::memory_order_relaxed)),
        @"rvqCoarse": @(shared->rvqCoarse.load(std::memory_order_relaxed)),
        @"rvqFine": @(shared->rvqFine.load(std::memory_order_relaxed)),
        @"rvqSweep": @(shared->rvqSweep.load(std::memory_order_relaxed)),
        @"rvqHold": @(shared->rvqHold.load(std::memory_order_relaxed)),
        @"rvqInvert": @(shared->rvqInvert.load(std::memory_order_relaxed)),
        @"rvqJitter": @(shared->rvqJitter.load(std::memory_order_relaxed)),
        @"rvqStride": @(shared->rvqStride.load(std::memory_order_relaxed)),
    };
}

- (NSDictionary*)currentAudioFeatureState {
    ColliderSharedState* shared = self.sharedState;
    if (!shared) return @{};

    int head = shared->vizHead.load(std::memory_order_acquire);
    static constexpr int WINDOW = 4096; // ~85 ms at 48 kHz
    double sumSquares = 0.0;
    double diffSquares = 0.0;
    double lowSquares = 0.0;
    double highSquares = 0.0;
    float peak = 0.0f;
    float previous = 0.0f;
    int zeroCrossings = 0;

    for (int i = 0; i < WINDOW; i++) {
        int idx = (head - WINDOW + i + ColliderSharedState::VIZ_BUF_SIZE) % ColliderSharedState::VIZ_BUF_SIZE;
        float sample = shared->vizRing[idx];
        float absSample = fabsf(sample);
        peak = fmaxf(peak, absSample);
        sumSquares += sample * sample;
        if (i > 0) {
            float diff = sample - previous;
            diffSquares += diff * diff;
            highSquares += diff * diff;
            if ((sample >= 0.0f && previous < 0.0f) || (sample < 0.0f && previous >= 0.0f)) {
                zeroCrossings++;
            }
        }
        float low = previous * 0.92f + sample * 0.08f;
        lowSquares += low * low;
        previous = sample;
    }

    double rms = sqrt(sumSquares / WINDOW);
    double diffRms = sqrt(diffSquares / fmax(1, WINDOW - 1));
    double lowRms = sqrt(lowSquares / WINDOW);
    double highRms = sqrt(highSquares / fmax(1, WINDOW - 1));
    double brightness = fmin(1.0, diffRms / fmax(1e-6, rms * 2.25));
    double roughness = fmin(1.0, highRms / fmax(1e-6, lowRms + highRms));
    double zcr = zeroCrossings / (double)WINDOW;
    double loudnessDb = 20.0 * log10(fmax(1e-6, rms));
    double onset = fmax(0.0, (rms - _agentLastRms) * 8.0 + (brightness - _agentLastBrightness) * 0.65);
    onset = fmin(1.0, onset);
    _agentLastRms = static_cast<float>(rms);
    _agentLastBrightness = static_cast<float>(brightness);

    return @{
        @"peak": @(peak),
        @"rms": @(rms),
        @"loudnessDb": @(loudnessDb),
        @"brightness": @(brightness),
        @"roughness": @(roughness),
        @"zeroCrossingRate": @(zcr),
        @"onset": @(onset),
        @"windowMs": @(WINDOW * 1000.0 / ColliderSharedState::kSampleRate)
    };
}

- (void)publishAgentPerformanceStateWithAudio:(NSDictionary*)audioFeatures
                                      metrics:(NSDictionary*)metrics {
    if (!_agentServer) return;

    NSMutableDictionary* payload = [NSMutableDictionary dictionary];
    payload[@"type"] = @"state";
    payload[@"schema_version"] = @1;
    payload[@"timestamp"] = confabulatorISODateString([NSDate date]);
    payload[@"transport"] = @{
        @"playing": @(_isPlaying),
        @"modelName": _modelName ?: @"No model loaded"
    };
    payload[@"audio"] = audioFeatures ?: @{};
    payload[@"metrics"] = metrics ?: @{};
    if (_lastAgentUiState) payload[@"ui"] = _lastAgentUiState;
    if (_lastAgentCatalog) payload[@"catalogVersion"] = _lastAgentCatalog[@"version"] ?: @1;
    [_agentServer broadcastJSONObject:payload];
}

- (void)applyFxKey:(NSString*)key value:(float)value {
    ColliderSharedState* shared = self.sharedState;
    if (!shared || !key) return;
    float v = fmaxf(0.0f, fminf(1.0f, value));
    if ([key isEqualToString:@"wet"]) shared->fxWet.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"drive"]) shared->fxDrive.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"fold"]) shared->fxFold.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"crush"]) shared->fxCrush.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"ring"]) shared->fxRing.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"comb"]) shared->fxComb.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"body"]) shared->fxBody.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"smear"]) shared->fxSmear.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"stutter"]) shared->fxStutter.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"pitch"]) shared->fxPitch.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"harmonics"]) shared->fxHarmonics.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"noise"]) shared->fxNoise.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"rvqForce"]) {
        shared->rvqForce.store(v, std::memory_order_relaxed);
        if (self.engine) self.engine->set_rvq_force(v);
    }
    else if ([key isEqualToString:@"rvqBreathe"]) {
        shared->rvqBreathe.store(v, std::memory_order_relaxed);
        if (self.engine) self.engine->set_rvq_breathe(v);
    }
    else if ([key isEqualToString:@"rvqMemory"]) {
        shared->rvqMemory.store(v, std::memory_order_relaxed);
        if (self.engine) self.engine->set_rvq_memory(v);
    }
    else if ([key isEqualToString:@"rvqCoarse"]) {
        shared->rvqCoarse.store(v, std::memory_order_relaxed);
        if (self.engine) self.engine->set_rvq_coarse(v);
    }
    else if ([key isEqualToString:@"rvqFine"]) {
        shared->rvqFine.store(v, std::memory_order_relaxed);
        if (self.engine) self.engine->set_rvq_fine(v);
    }
    else if ([key isEqualToString:@"rvqSweep"]) {
        shared->rvqSweep.store(v, std::memory_order_relaxed);
        if (self.engine) self.engine->set_rvq_sweep(v);
    }
    else if ([key isEqualToString:@"rvqHold"]) {
        shared->rvqHold.store(v, std::memory_order_relaxed);
        if (self.engine) self.engine->set_rvq_hold(v);
    }
    else if ([key isEqualToString:@"rvqInvert"]) {
        shared->rvqInvert.store(v, std::memory_order_relaxed);
        if (self.engine) self.engine->set_rvq_invert(v);
    }
    else if ([key isEqualToString:@"rvqJitter"]) {
        shared->rvqJitter.store(v, std::memory_order_relaxed);
        if (self.engine) self.engine->set_rvq_jitter(v);
    }
    else if ([key isEqualToString:@"rvqStride"]) {
        shared->rvqStride.store(v, std::memory_order_relaxed);
        if (self.engine) self.engine->set_rvq_stride(v);
    }
}

- (NSDictionary*)currentRecorderStateWithStatus:(NSString*)status
                                       filePath:(NSString*)filePath
                                    sidecarPath:(NSString*)sidecarPath
                                          error:(NSString*)error {
    ColliderSharedState* shared = self.sharedState;
    if (!shared) return @{};
    NSMutableDictionary* state = [NSMutableDictionary dictionary];
    state[@"rolling"] = @YES;
    state[@"rollingSeconds"] = @(shared->getRollingSeconds());
    state[@"availableSeconds"] = @(shared->getAvailableRollingSamples() / (double)ColliderSharedState::kSampleRate);
    state[@"recording"] = @(shared->retroRecording.load(std::memory_order_acquire));
    state[@"recordingSeconds"] = @(shared->getRetroRecordingSeconds());
    state[@"maxLiveSeconds"] = @(ColliderSharedState::kMaxRetroLiveSeconds);
    if (status) state[@"status"] = status;
    if (filePath) state[@"filePath"] = filePath;
    if (sidecarPath) state[@"sidecarPath"] = sidecarPath;
    if (error) state[@"error"] = error;
    return state;
}

- (BOOL)exportRecordingLeft:(const std::vector<float>&)left
                      right:(const std::vector<float>&)right
                       mode:(NSString*)mode
           requestedSeconds:(double)requestedSeconds
                      patch:(NSDictionary*)patch
                    wavPath:(NSString**)outWavPath
                sidecarPath:(NSString**)outSidecarPath
                      error:(NSString**)outError {
    if (left.empty() || right.empty()) {
        if (outError) *outError = @"No audio available in rolling buffer yet.";
        return NO;
    }

    NSDate* now = [NSDate date];
    NSString* captureDir = confabulatorCaptureDirectory();
    NSString* safeMode = confabulatorSafeModeName(mode);
    NSString* baseName = [NSString stringWithFormat:@"CONFABULATOR_%@_%@",
                          confabulatorFileTimestamp(now), safeMode];
    NSString* wavPath = [captureDir stringByAppendingPathComponent:
                         [baseName stringByAppendingPathExtension:@"wav"]];
    NSString* sidecarPath = [captureDir stringByAppendingPathComponent:
                             [baseName stringByAppendingPathExtension:@"confab.json"]];

    if (!confabWriteFloat32Wav(wavPath, left, right, ColliderSharedState::kSampleRate)) {
        if (outError) *outError = @"Could not write WAV file.";
        return NO;
    }

    NSProcessInfo* processInfo = [NSProcessInfo processInfo];
    NSDictionary* metadata = @{
        @"timestamp": confabulatorISODateString(now),
        @"model_name": _modelName ?: @"No model loaded",
        @"application_version": [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0",
        @"build_version": [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"0",
        @"operating_system": processInfo.operatingSystemVersionString ?: @"macOS",
        @"host_name": processInfo.hostName ?: @"unknown",
        @"processor_count": @(processInfo.processorCount)
    };

    NSDictionary* recording = @{
        @"mode": mode ?: @"capture",
        @"sample_rate": @(ColliderSharedState::kSampleRate),
        @"channels": @2,
        @"format": @"wav_float32",
        @"sample_count": @(std::min(left.size(), right.size())),
        @"duration_seconds": @(std::min(left.size(), right.size()) / (double)ColliderSharedState::kSampleRate),
        @"requested_seconds": @(requestedSeconds),
        @"audio_path": wavPath.lastPathComponent,
        @"sidecar_path": sidecarPath.lastPathComponent
    };

    NSDictionary* sidecar = @{
        @"schema_version": @1,
        @"metadata": metadata,
        @"recording": recording,
        @"patch": patch ?: @{}
    };

    NSError* jsonError = nil;
    NSData* jsonData = [NSJSONSerialization dataWithJSONObject:sidecar
                                                       options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                         error:&jsonError];
    if (!jsonData || jsonError) {
        if (outError) *outError = jsonError.localizedDescription ?: @"Could not create sidecar JSON.";
        return NO;
    }
    if (![jsonData writeToFile:sidecarPath atomically:YES]) {
        if (outError) *outError = @"Could not write sidecar JSON.";
        return NO;
    }

    if (outWavPath) *outWavPath = wavPath;
    if (outSidecarPath) *outSidecarPath = sidecarPath;
    return YES;
}

- (void)handleRecorderSetWindow:(NSDictionary*)body {
    NSNumber* seconds = body[@"seconds"];
    if (self.sharedState && [seconds isKindOfClass:[NSNumber class]]) {
        self.sharedState->setRollingSeconds(seconds.intValue);
        [self sendStateUpdate:@{@"recorder": [self currentRecorderStateWithStatus:@"window"
                                                                         filePath:nil
                                                                      sidecarPath:nil
                                                                            error:nil]}];
    }
}

- (void)handleRecorderCaptureLast:(NSDictionary*)body {
    if (!self.sharedState) return;
    NSNumber* secondsNumber = body[@"seconds"];
    NSString* mode = [body[@"mode"] isKindOfClass:[NSString class]] ? body[@"mode"] : @"last";
    NSDictionary* patch = [body[@"patch"] isKindOfClass:[NSDictionary class]] ? body[@"patch"] : @{};
    int seconds = [secondsNumber isKindOfClass:[NSNumber class]]
        ? secondsNumber.intValue
        : self.sharedState->getRollingSeconds();

    std::vector<float> left;
    std::vector<float> right;
    if (!self.sharedState->copyLastSeconds(seconds, left, right)) {
        [self sendStateUpdate:@{@"recorder": [self currentRecorderStateWithStatus:@"error"
                                                                         filePath:nil
                                                                      sidecarPath:nil
                                                                            error:@"No audio available in rolling buffer yet."]}];
        return;
    }

    NSString* wavPath = nil;
    NSString* sidecarPath = nil;
    NSString* error = nil;
    BOOL ok = [self exportRecordingLeft:left
                                  right:right
                                   mode:mode
                       requestedSeconds:seconds
                                  patch:patch
                                wavPath:&wavPath
                            sidecarPath:&sidecarPath
                                  error:&error];
    [self sendStateUpdate:@{@"recorder": [self currentRecorderStateWithStatus:(ok ? @"saved" : @"error")
                                                                     filePath:wavPath
                                                                  sidecarPath:sidecarPath
                                                                        error:error]}];
}

- (void)handleRecorderStart:(NSDictionary*)body {
    if (!self.sharedState) return;
    NSNumber* secondsNumber = body[@"seconds"];
    int seconds = [secondsNumber isKindOfClass:[NSNumber class]]
        ? secondsNumber.intValue
        : self.sharedState->getRollingSeconds();
    self.sharedState->startRetroRecording(seconds);
    [self sendStateUpdate:@{@"recorder": [self currentRecorderStateWithStatus:@"recording"
                                                                     filePath:nil
                                                                  sidecarPath:nil
                                                                        error:nil]}];
}

- (void)handleRecorderStop:(NSDictionary*)body {
    if (!self.sharedState) return;
    NSDictionary* patch = [body[@"patch"] isKindOfClass:[NSDictionary class]] ? body[@"patch"] : @{};
    std::vector<float> left;
    std::vector<float> right;
    if (!self.sharedState->stopRetroRecording(left, right)) {
        [self sendStateUpdate:@{@"recorder": [self currentRecorderStateWithStatus:@"error"
                                                                         filePath:nil
                                                                      sidecarPath:nil
                                                                            error:@"No retro recording audio available."]}];
        return;
    }

    NSString* wavPath = nil;
    NSString* sidecarPath = nil;
    NSString* error = nil;
    BOOL ok = [self exportRecordingLeft:left
                                  right:right
                                   mode:@"retro"
                       requestedSeconds:(left.size() / (double)ColliderSharedState::kSampleRate)
                                  patch:patch
                                wavPath:&wavPath
                            sidecarPath:&sidecarPath
                                  error:&error];
    [self sendStateUpdate:@{@"recorder": [self currentRecorderStateWithStatus:(ok ? @"saved" : @"error")
                                                                     filePath:wavPath
                                                                  sidecarPath:sidecarPath
                                                                        error:error]}];
}

- (void)handleAgentState:(NSDictionary*)body {
    NSDictionary* value = [body[@"value"] isKindOfClass:[NSDictionary class]] ? body[@"value"] : nil;
    if (!value) return;
    _lastAgentUiState = value;
}

- (void)handleAgentCatalog:(NSDictionary*)body {
    NSDictionary* value = [body[@"value"] isKindOfClass:[NSDictionary class]] ? body[@"value"] : nil;
    if (!value) return;
    _lastAgentCatalog = value;
    [_agentServer broadcastJSONObject:@{
        @"type": @"catalog",
        @"schema_version": @1,
        @"timestamp": confabulatorISODateString([NSDate date]),
        @"catalog": value
    }];
}

- (NSArray<NSDictionary*>*)agentWelcomeMessages {
    NSMutableArray<NSDictionary*>* messages = [NSMutableArray array];
    if (_lastAgentCatalog) {
        [messages addObject:@{
            @"type": @"catalog",
            @"schema_version": @1,
            @"timestamp": confabulatorISODateString([NSDate date]),
            @"catalog": _lastAgentCatalog
        }];
    }
    if (_lastAgentUiState) {
        [messages addObject:@{
            @"type": @"state",
            @"schema_version": @1,
            @"timestamp": confabulatorISODateString([NSDate date]),
            @"audio": @{},
            @"metrics": @{},
            @"ui": _lastAgentUiState
        }];
    }
    return messages;
}

- (void)handleAgentSocketCommand:(NSDictionary*)command {
    if (!command) return;
    NSString* commandId = [command[@"id"] isKindOfClass:[NSString class]] ? command[@"id"] : nil;
    NSMutableDictionary* ack = [NSMutableDictionary dictionary];
    ack[@"type"] = @"ack";
    ack[@"schema_version"] = @1;
    ack[@"timestamp"] = confabulatorISODateString([NSDate date]);
    ack[@"ok"] = @YES;
    if (commandId) ack[@"id"] = commandId;
    if ([command[@"type"] isKindOfClass:[NSString class]]) ack[@"command"] = command[@"type"];
    [_agentServer broadcastJSONObject:ack];

    [self sendStateUpdate:@{@"agentCommand": command}];
}

- (void)showReactSettings {
    [self sendStateUpdate:@{@"openSettings": @YES}];
}

- (void)connectToEngine {
    RealtimeRunner* engine = self.engine;
    if (!engine) return;

    NSMutableDictionary* initialParams = [NSMutableDictionary dictionary];
    int addresses[] = {0,1,3,4,5,6,7,8,9,32,33,34,35,36,37,38,39,47,48};
    for (int addr : addresses) {
        NSString* key = [MagentaSettings paramKeyForAddress:addr];
        if (!key) continue;
        float rawVal = [self readParamFromEngine:addr];
        NSNumber* val = [MagentaSettings paramIsBool:addr] ? @(rawVal > 0.5) : @(rawVal);
        initialParams[key] = val;
        _lastParams[key] = val;
    }

    NSMutableDictionary* state = [NSMutableDictionary dictionary];
    state[@"params"] = initialParams;
    state[@"isPlaying"] = @(_isPlaying);
    if (_modelName) state[@"modelName"] = _modelName;

    // Restore saved prompt
    NSString* savedPrompt = [[NSUserDefaults standardUserDefaults] stringForKey:@"Confabulator_Prompt"];
    if (savedPrompt) state[@"prompt"] = savedPrompt;

    // Restore saved prompt history
    NSArray* savedHistory = [[NSUserDefaults standardUserDefaults] arrayForKey:@"Confabulator_PromptHistory"];
    if (savedHistory) {
        state[@"savedPromptHistory"] = savedHistory;
        state[@"savedHistoryIndex"] = [[NSUserDefaults standardUserDefaults] objectForKey:@"Confabulator_HistoryIndex"] ?: @0;
    }

    NSNumber* savedPalette = [[NSUserDefaults standardUserDefaults] objectForKey:@"Confabulator_PaletteIndex"];
    if (savedPalette) state[@"savedPaletteIndex"] = savedPalette;

    state[@"fx"] = [self currentFxState];
    state[@"computerKeyboardMidi"] = @([[NSUserDefaults standardUserDefaults] boolForKey:@"Confabulator_ComputerKeyboardMidi"]);

    NSString* searchPath = [[NSUserDefaults standardUserDefaults] stringForKey:@"MagentaRT_ModelFolderPath"];
    if (!searchPath) {
        searchPath = [NSString stringWithUTF8String:magentart::paths::get_models_dir().c_str()];
    }
    state[@"resourcesMissing"] = @(![MagentaModelDownloader areSharedResourcesValid]);

    [self sendStateUpdate:state];
    [self handleListLocalModels];
}

- (void)setComputerKeyboardMidiEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"Confabulator_ComputerKeyboardMidi"];
    [self sendStateUpdate:@{@"computerKeyboardMidi": @(enabled)}];
}

- (void)notifyModelLoaded:(NSString*)modelName {
    _modelName = modelName;

    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableDictionary* state = [NSMutableDictionary dictionary];
        state[@"modelName"] = modelName;

        NSMutableDictionary* params = [NSMutableDictionary dictionary];
        int addresses[] = {0,1,3,4,5,6,7,8,9,32,33,34,35,36,37,38,39,47,48};
        for (int addr : addresses) {
            NSString* key = [MagentaSettings paramKeyForAddress:addr];
            if (!key) continue;
            float rawVal = [self readParamFromEngine:addr];
            params[key] = [MagentaSettings paramIsBool:addr] ? @(rawVal > 0.5) : @(rawVal);
            self->_lastParams[key] = params[key];
        }
        state[@"params"] = params;

        // Always push a prompt to the engine after model load so embeddings are
        // computed from the current text (UI default, saved value, or current
        // in-memory prompt). Without this, the engine runs on hardcoded fallback
        // musiccoca tokens until the user edits the prompt field.
        if (self.engine) {
            NSString* savedPrompt = [[NSUserDefaults standardUserDefaults] stringForKey:@"Confabulator_Prompt"];
            NSString* promptToUse = self->_currentPromptText.length > 0 ? self->_currentPromptText
                                    : (savedPrompt.length > 0 ? savedPrompt : @"funky bass guitar");
            self->_currentPromptText = promptToUse;
            state[@"prompt"] = promptToUse;
            std::vector<std::string> texts = {promptToUse.UTF8String, "", "", "", "", ""};
            std::vector<float> weights = {1.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
            self.engine->set_text_prompts(texts, weights);
        }

        [self sendStateUpdate:state];
    });
}

// ─── Navigation delegate ─────────────────────────────────────────────────────

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    NSLog(@"CONFABULATOR: WKWebView loaded");
}

// ─── UI delegate ─────────────────────────────────────────────────────────────

- (void)webView:(WKWebView *)webView
runOpenPanelWithParameters:(WKOpenPanelParameters *)parameters
initiatedByFrame:(WKFrameInfo *)frame
completionHandler:(void (^)(NSArray<NSURL *> * _Nullable URLs))completionHandler {
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = parameters.allowsMultipleSelection;
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"json"]];
    panel.message = @"Load a CONFABULATOR recipe (.confab.json)";

    NSWindow* window = self.view.window;
    void (^finish)(NSModalResponse) = ^(NSModalResponse result) {
        completionHandler(result == NSModalResponseOK ? panel.URLs : @[]);
    };

    if (window) {
        [panel beginSheetModalForWindow:window completionHandler:finish];
    } else {
        finish([panel runModal]);
    }
}

// ─── Script message handler ──────────────────────────────────────────────────

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:@"auHost"] || ![message.body isKindOfClass:[NSDictionary class]]) return;
    NSDictionary* body = message.body;
    NSString* type = body[@"type"];

    if ([type isEqualToString:@"param"]) {
        NSNumber* indexValue = body[@"index"];
        NSNumber* paramValue = body[@"value"];
        if (indexValue && paramValue) {
            [self applyParamToEngine:indexValue.intValue value:paramValue.floatValue];
        }
    }
    else if ([type isEqualToString:@"fx"]) {
        NSString* key = body[@"key"];
        NSNumber* value = body[@"value"];
        if ([key isKindOfClass:[NSString class]] && [value isKindOfClass:[NSNumber class]]) {
            [self applyFxKey:key value:value.floatValue];
        }
    }
    else if ([type isEqualToString:@"recorderSetWindow"]) {
        [self handleRecorderSetWindow:body];
    }
    else if ([type isEqualToString:@"recorderCaptureLast"]) {
        [self handleRecorderCaptureLast:body];
    }
    else if ([type isEqualToString:@"recorderStart"]) {
        [self handleRecorderStart:body];
    }
    else if ([type isEqualToString:@"recorderStop"]) {
        [self handleRecorderStop:body];
    }
    else if ([type isEqualToString:@"agentState"]) {
        [self handleAgentState:body];
    }
    else if ([type isEqualToString:@"agentCatalog"]) {
        [self handleAgentCatalog:body];
    }
    else if ([type isEqualToString:@"textPrompts"]) {
        NSArray* promptsArray = body[@"value"];
        if ([promptsArray isKindOfClass:[NSArray class]] && self.engine) {
            std::vector<std::string> texts;
            std::vector<float> weights;
            std::vector<std::vector<float>> embeddings;
            std::vector<bool> hasEmbedding;
            std::vector<std::string> kinds;
            for (NSDictionary* p in promptsArray) {
                NSString* text = p[@"text"];
                NSNumber* weight = p[@"weight"];
                NSString* kind = p[@"kind"];
                NSArray* embedding = p[@"embedding"];
                if ([text isKindOfClass:[NSString class]] && [weight isKindOfClass:[NSNumber class]]) {
                    texts.push_back(text.UTF8String);
                    weights.push_back(weight.floatValue);

                    kinds.push_back([kind isKindOfClass:[NSString class]] ? kind.UTF8String : "text");
                    std::vector<float> emb;
                    if ([embedding isKindOfClass:[NSArray class]] && embedding.count == 768) {
                        emb.reserve(768);
                        BOOL ok = YES;
                        for (id value in embedding) {
                            if (![value isKindOfClass:[NSNumber class]]) {
                                ok = NO;
                                break;
                            }
                            emb.push_back([(NSNumber*)value floatValue]);
                        }
                        hasEmbedding.push_back(ok && emb.size() == 768);
                    } else {
                        hasEmbedding.push_back(false);
                    }
                    embeddings.push_back(std::move(emb));
                }
            }
            for (int i = 0; i < 6; ++i) {
                if (i < (int)hasEmbedding.size() && hasEmbedding[i]) {
                    self.engine->set_audio_embedding(i, embeddings[i].data());
                } else if (!(i < (int)kinds.size() && kinds[i] == "audio")) {
                    self.engine->set_audio_embedding(i, nullptr);
                }
            }
            self.engine->set_text_prompts(texts, weights);
            self.engine->set_blend_weights(weights.data(), (int)weights.size());

            // Persist current prompt and history
            if (texts.size() > 0) {
                NSString* prompt = [NSString stringWithUTF8String:texts[0].c_str()];
                _currentPromptText = prompt;
                [[NSUserDefaults standardUserDefaults] setObject:prompt forKey:@"Confabulator_Prompt"];
            }
        }
    }
    else if ([type isEqualToString:@"requestPromptEmbedding"]) {
        NSNumber* indexValue = body[@"index"];
        NSNumber* nodeIdValue = body[@"nodeId"];
        if (!self.engine || ![indexValue isKindOfClass:[NSNumber class]] || ![nodeIdValue isKindOfClass:[NSNumber class]]) {
            if ([nodeIdValue isKindOfClass:[NSNumber class]]) {
                [self sendStateUpdate:@{@"promptEmbeddingError": @{@"nodeId": nodeIdValue, @"reason": @"engine-not-ready"}}];
            }
            return;
        }

        float embedding[kMusicCoCaEmbeddingDim] = {};
        BOOL ok = self.engine->get_prompt_embedding(indexValue.intValue, embedding);
        if (!ok) {
            [self sendStateUpdate:@{@"promptEmbeddingError": @{@"nodeId": nodeIdValue, @"reason": @"not-ready"}}];
            return;
        }

        NSMutableArray* values = [NSMutableArray arrayWithCapacity:kMusicCoCaEmbeddingDim];
        for (int i = 0; i < kMusicCoCaEmbeddingDim; ++i) {
            [values addObject:@(embedding[i])];
        }
        [self sendStateUpdate:@{@"promptEmbedding": @{@"nodeId": nodeIdValue, @"embedding": values}}];
    }
    else if ([type isEqualToString:@"loadModel"]) {
        [self handleLoadModel];
    }
    else if ([type isEqualToString:@"listLocalModels"]) {
        [self handleListLocalModels];
    }
    else if ([type isEqualToString:@"listRemoteModels"]) {
        [MagentaModelDownloader listRemoteModelsWithCompletion:^(NSArray<NSString *> *models, NSError *error) {
            if (error) {
                [self sendStateUpdate:@{@"remoteModelsError": error.localizedDescription}];
            } else {
                [self sendStateUpdate:@{@"remoteModels": models}];
            }
        }];
    }
    else if ([type isEqualToString:@"downloadModel"]) {
        NSString* name = body[@"name"];
        if (name) {
            [MagentaModelDownloader downloadModel:name progress:^(double progress, NSString *status) {
                [self sendStateUpdate:@{
                    @"downloadProgress": @{
                        @"status": @"downloading",
                        @"percent": @(progress),
                        @"text": status,
                        @"modelName": name
                    }
                }];
            } completion:^(BOOL success, NSError *error) {
                if (success) {
                    [self sendStateUpdate:@{
                        @"downloadProgress": @{
                            @"status": @"success",
                            @"percent": @(1.0),
                            @"text": @"Download Complete!",
                            @"modelName": name
                        }
                    }];
                    [self handleListLocalModels];
                } else {
                    [self sendStateUpdate:@{
                        @"downloadProgress": @{
                            @"status": @"error",
                            @"percent": @(0.0),
                            @"text": error.localizedDescription ?: @"Download Failed",
                            @"modelName": name
                        }
                    }];
                }
            }];
        }
    }
    else if ([type isEqualToString:@"deleteModel"]) {
        NSString* name = body[@"name"];
        if (name) {
            [self handleDeleteModel:name];
        }
    }
    else if ([type isEqualToString:@"initResources"]) {
        NSString* name = body[@"modelName"];
        [self handleInitResources:name];
    }
    else if ([type isEqualToString:@"selectDownloadFolder"]) {
        [self handleSelectDownloadFolder];
    }
    else if ([type isEqualToString:@"selectModel"]) {
        NSString* name = body[@"name"];
        if (name) {
            [self handleSelectModel:name];
        }
    }
    else if ([type isEqualToString:@"loadAudioPrompt"]) {
        [self handleLoadAudioPrompt:0];
    }
    else if ([type isEqualToString:@"clearAudioPrompt"]) {
        if (self.engine) {
            self.engine->set_audio_prompt(0, "");
        }
        [self sendStateUpdate:@{
            @"prompt": _currentPromptText ?: @"funky bass guitar",
            @"isAudioPrompt": @NO,
        }];
    }
    else if ([type isEqualToString:@"kbdNote"]) {
        NSNumber* noteVal = body[@"note"];
        NSNumber* onVal = body[@"on"];
        if (!noteVal || !onVal || !self.engine) return;
        uint8_t note = (uint8_t)MIN(127, MAX(0, noteVal.intValue));
        BOOL on = onVal.boolValue;
        if (on) {
            self.engine->set_note_on(note);
            if (self.sharedState) self.sharedState->noteOn(note);
        } else {
            self.engine->set_note_off(note);
            if (self.sharedState) self.sharedState->noteOff(note);
        }
    }
    else if ([type isEqualToString:@"togglePlay"]) {
        [self setTransportPlaying:!_isPlaying reset:YES];
    }
    else if ([type isEqualToString:@"openSettings"]) {
        [NSApp sendAction:@selector(menuShowSettings:) to:nil from:self];
    }
    else if ([type isEqualToString:@"savePromptHistory"]) {
        NSArray* history = body[@"history"];
        NSNumber* index = body[@"index"];
        NSNumber* palette = body[@"paletteIndex"];
        if (history) [[NSUserDefaults standardUserDefaults] setObject:history forKey:@"Confabulator_PromptHistory"];
        if (index) [[NSUserDefaults standardUserDefaults] setObject:index forKey:@"Confabulator_HistoryIndex"];
        if (palette) [[NSUserDefaults standardUserDefaults] setObject:palette forKey:@"Confabulator_PaletteIndex"];
    }
    else if ([type isEqualToString:@"log"]) {
        NSString* val = body[@"value"];
        if (val) NSLog(@"CONFABULATOR UI: %@", val);
    }
    else if ([type isEqualToString:@"uiReady"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self connectToEngine];
        });
    }
}

// ─── Model loading (shared core) ─────────────────────────────────────────────

- (void)loadModelAtPath:(NSString*)mlxfnPath {
    RealtimeRunner* engine = self.engine;
    if (!engine) return;

    NSLog(@"CONFABULATOR: Loading model from %@", mlxfnPath);
    BOOL success = engine->load_model(mlxfnPath.UTF8String);

    if (success) {
        self->_modelName = mlxfnPath.lastPathComponent;

        // Auto-load corpus
        NSString* parentDir = [mlxfnPath stringByDeletingLastPathComponent];
        NSString* corpusPath = [parentDir stringByAppendingPathComponent:@"corpus.safetensors"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:corpusPath]) {
            engine->load_pca_file(corpusPath.UTF8String);
        }

        // Always push a prompt to the engine, falling back through
        // current → saved → bundled default.
        NSString* savedPrompt = [[NSUserDefaults standardUserDefaults] stringForKey:@"Confabulator_Prompt"];
        NSString* promptToUse = self->_currentPromptText.length > 0 ? self->_currentPromptText
                                : (savedPrompt.length > 0 ? savedPrompt : @"funky bass guitar");
        self->_currentPromptText = promptToUse;
        {
            std::vector<std::string> texts = {promptToUse.UTF8String, "", "", "", "", ""};
            std::vector<float> weights = {1.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
            engine->set_text_prompts(texts, weights);
        }

        [self sendStateUpdate:@{
            @"modelName": mlxfnPath.lastPathComponent,
            @"prompt": promptToUse
        }];

        [[NSUserDefaults standardUserDefaults] setObject:mlxfnPath forKey:@"Confabulator_ModelPath"];
    } else {
        [self sendStateUpdate:@{@"modelName": [NSString stringWithFormat:@"Failed: %@", mlxfnPath.lastPathComponent]}];
    }
}

- (void)handleLoadModel {
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    [panel setCanChooseFiles:YES];
    [panel setCanChooseDirectories:YES];
    [panel setMessage:@"Select the directory containing your model, or the .mlxfn file."];

    void (^completionBlock)(NSModalResponse) = ^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSURL* url = [panel URL];
        if (!url) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            RealtimeRunner* engine = self.engine;
            if (!engine) return;

            NSString* path = url.path;
            BOOL isDir = NO;
            [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];

            NSString* mlxfnPath = nil;
            if (isDir) {
                NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:nil];
                for (NSString *file in contents) {
                    if ([file hasSuffix:@".mlxfn"]) {
                        mlxfnPath = [path stringByAppendingPathComponent:file];
                        break;
                    }
                }
            } else if ([path hasSuffix:@".mlxfn"]) {
                mlxfnPath = path;
            }

            if (!mlxfnPath) {
                [self sendStateUpdate:@{@"modelName": @"No .mlxfn found"}];
                return;
            }

            [self loadModelAtPath:mlxfnPath];
        });
    };

    if (self.view.window) {
        [panel beginSheetModalForWindow:self.view.window completionHandler:completionBlock];
    } else {
        [panel beginWithCompletionHandler:completionBlock];
    }
}

- (void)handleSelectDownloadFolder {
    [MagentaModelManager selectDownloadFolderWithParentWindow:self.view.window
                                                  completion:^(NSString *selectedPath, NSData *bookmarkData, NSError *error) {
        if (selectedPath) {
            dispatch_async(dispatch_get_main_queue(), ^{
                // Save custom path bookmarks
                [[NSUserDefaults standardUserDefaults] setObject:bookmarkData forKey:@"MagentaRT_ModelFolderBookmark"];
                [[NSUserDefaults standardUserDefaults] setObject:selectedPath forKey:@"MagentaRT_ModelFolderPath"];

                // Determine if custom resources folder exists inside the selected path
                NSString *customResourcesPath = [selectedPath stringByAppendingPathComponent:@"resources"];
                BOOL hasCustomResources = [[NSFileManager defaultManager] fileExistsAtPath:customResourcesPath];

                NSString *resourcesPathToLoad = hasCustomResources ? customResourcesPath : [NSString stringWithUTF8String:magentart::paths::get_resources_dir().c_str()];

                // Re-initialize the C++ engine with this selected resources folder!
                if (!self.engine->init_assets(resourcesPathToLoad.UTF8String)) {
                    NSLog(@"CONFABULATOR: Failed to initialize C++ assets from custom path: %@", resourcesPathToLoad);
                } else {
                    NSLog(@"CONFABULATOR: Successfully initialized C++ assets from path: %@", resourcesPathToLoad);
                    // Save custom resources path for subsequent launches!
                    [[NSUserDefaults standardUserDefaults] setObject:resourcesPathToLoad forKey:@"MagentaRT_CustomResourcesPath"];
                }
                // Force close the onboarding modal!
                [self sendStateUpdate:@{
                    @"downloadPath": selectedPath,
                    @"resourcesMissing": @NO // Close onboarding modal instantly!
                }];

                [self handleListLocalModels];

                // Programmatically auto-load the first available model in the newly selected folder if present!
                NSArray<NSString *> *modelFiles = [MagentaModelManager listLocalModelsInDirectory:[NSURL fileURLWithPath:selectedPath]];
                if (modelFiles.count > 0) {
                    [self handleSelectModel:modelFiles[0]];
                }
            });
        } else if (error) {
            NSLog(@"CONFABULATOR: Failed to create folder bookmark: %@", error.localizedDescription);
        }
    }];
}

- (void)handleListLocalModels {
    NSData* bookmark = [[NSUserDefaults standardUserDefaults] objectForKey:@"MagentaRT_ModelFolderBookmark"];
    NSURL* modelsDir = nil;
    BOOL accessGranted = NO;

    if (bookmark) {
        BOOL stale = NO;
        modelsDir = [NSURL URLByResolvingBookmarkData:bookmark options:NSURLBookmarkResolutionWithSecurityScope relativeToURL:nil bookmarkDataIsStale:&stale error:nil];
        if (modelsDir) {
            accessGranted = [modelsDir startAccessingSecurityScopedResource];
        }
    }

    if (!modelsDir) {
        std::string defaultPath = magentart::paths::get_models_dir();
        modelsDir = [NSURL fileURLWithPath:[NSString stringWithUTF8String:defaultPath.c_str()]];
    }

    [[NSFileManager defaultManager] createDirectoryAtURL:modelsDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSArray<NSString *> *modelFiles = [MagentaModelManager listLocalModelsInDirectory:modelsDir];

    if (accessGranted) {
        [modelsDir stopAccessingSecurityScopedResource];
    }

    [self sendStateUpdate:@{@"localModels": modelFiles}];
}

- (void)handleSelectModel:(NSString*)modelName {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.engine) return;

        NSData* bookmark = [[NSUserDefaults standardUserDefaults] objectForKey:@"MagentaRT_ModelFolderBookmark"];
        NSURL* modelsDir = nil;
        BOOL accessGranted = NO;

        if (bookmark) {
            BOOL stale = NO;
            modelsDir = [NSURL URLByResolvingBookmarkData:bookmark options:NSURLBookmarkResolutionWithSecurityScope relativeToURL:nil bookmarkDataIsStale:&stale error:nil];
            if (modelsDir) {
                accessGranted = [modelsDir startAccessingSecurityScopedResource];
            }
        }

        if (!modelsDir) {
            std::string defaultPath = magentart::paths::get_models_dir();
            modelsDir = [NSURL fileURLWithPath:[NSString stringWithUTF8String:defaultPath.c_str()]];
        }

        NSURL* modelURL = [modelsDir URLByAppendingPathComponent:modelName];
        NSString* path = modelURL.path;
        BOOL isDir = NO;
        [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];

        NSString* mlxfnPath = nil;
        if ([path hasSuffix:@".mlxfn"]) {
            mlxfnPath = path;
        } else if (isDir) {
            std::string dirPathStr = path.UTF8String;
            std::string foundMlxfn = magentart::paths::find_mlxfn_in_dir(dirPathStr);
            if (!foundMlxfn.empty()) {
                mlxfnPath = [NSString stringWithUTF8String:foundMlxfn.c_str()];
            }
        }

        if (!mlxfnPath) {
            [self sendStateUpdate:@{@"modelName": @"No .mlxfn found"}];
            if (accessGranted) [modelsDir stopAccessingSecurityScopedResource];
            return;
        }

        [self loadModelAtPath:mlxfnPath];
        [[NSUserDefaults standardUserDefaults] setObject:modelName forKey:@"Confabulator_LoadedModelName"];

        if (accessGranted) {
            [modelsDir stopAccessingSecurityScopedResource];
        }
    });
}

// ─── Audio prompt loading ────────────────────────────────────────────────────

- (void)handleLoadAudioPrompt:(int)index {
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    [panel setCanChooseFiles:YES];
    [panel setCanChooseDirectories:NO];
    [panel setAllowedContentTypes:@[[UTType typeWithIdentifier:@"public.audio"]]];
    [panel setMessage:@"Select an audio file for the prompt"];

    void (^completionBlock)(NSModalResponse) = ^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSURL* url = [panel URL];
        if (!url) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            RealtimeRunner* engine = self.engine;
            if (!engine) return;

            NSString* filename = url.lastPathComponent;
            BOOL readSuccess = NO;

            ExtAudioFileRef extFile = nullptr;
            OSStatus status = ExtAudioFileOpenURL((__bridge CFURLRef)url, &extFile);
            if (status == noErr && extFile) {
                AudioStreamBasicDescription clientFormat = {};
                clientFormat.mSampleRate = 16000.0;
                clientFormat.mFormatID = kAudioFormatLinearPCM;
                clientFormat.mFormatFlags = kAudioFormatFlagIsFloat;
                clientFormat.mBitsPerChannel = 32;
                clientFormat.mChannelsPerFrame = 1;
                clientFormat.mBytesPerFrame = 4;
                clientFormat.mFramesPerPacket = 1;
                clientFormat.mBytesPerPacket = 4;

                status = ExtAudioFileSetProperty(extFile, kExtAudioFileProperty_ClientDataFormat,
                                                  sizeof(clientFormat), &clientFormat);
                if (status == noErr) {
                    int maxFrames = 160000;
                    std::vector<float> samples(maxFrames, 0.0f);
                    AudioBufferList bufferList;
                    bufferList.mNumberBuffers = 1;
                    bufferList.mBuffers[0].mNumberChannels = 1;
                    bufferList.mBuffers[0].mDataByteSize = maxFrames * sizeof(float);
                    bufferList.mBuffers[0].mData = samples.data();

                    UInt32 framesToRead = maxFrames;
                    status = ExtAudioFileRead(extFile, &framesToRead, &bufferList);
                    if (status == noErr && framesToRead > 0) {
                        if (framesToRead < (UInt32)maxFrames) {
                            for (UInt32 i = framesToRead; i < (UInt32)maxFrames; ++i)
                                samples[i] = samples[i % framesToRead];
                        }
                        engine->set_audio_prompt_samples(index, filename.UTF8String, samples.data(), maxFrames);
                        readSuccess = YES;
                    }
                }
                ExtAudioFileDispose(extFile);
            }

            [self sendStateUpdate:@{
                @"prompt": readSuccess ? filename : @"Error: Load failed",
                @"isAudioPrompt": @(readSuccess),
            }];
        });
    };

    if (self.view.window) {
        [panel beginSheetModalForWindow:self.view.window completionHandler:completionBlock];
    } else {
        [panel beginWithCompletionHandler:completionBlock];
    }
}

- (void)handleDeleteModel:(NSString *)modelName {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSData* bookmark = [[NSUserDefaults standardUserDefaults] objectForKey:@"Confabulator_ModelSearchBookmark"];
        NSURL* modelsDir = nil;
        BOOL accessGranted = NO;

        if (bookmark) {
            BOOL stale = NO;
            modelsDir = [NSURL URLByResolvingBookmarkData:bookmark options:NSURLBookmarkResolutionWithSecurityScope relativeToURL:nil bookmarkDataIsStale:&stale error:nil];
            if (modelsDir) {
                accessGranted = [modelsDir startAccessingSecurityScopedResource];
            }
        }

        if (!modelsDir) {
            std::string defaultPath = magentart::paths::get_models_dir();
            modelsDir = [NSURL fileURLWithPath:[NSString stringWithUTF8String:defaultPath.c_str()]];
        }

        NSURL* modelURL = [modelsDir URLByAppendingPathComponent:modelName];
        NSString* path = modelURL.path;

        NSError *error = nil;
        [[NSFileManager defaultManager] removeItemAtPath:path error:&error];
        if (error) {
            NSLog(@"CONFABULATOR: Failed to delete model %@: %@", modelName, error.localizedDescription);
        } else {
            NSLog(@"CONFABULATOR: Successfully deleted model %@", modelName);
            [self handleListLocalModels];
        }

        if (accessGranted) {
            [modelsDir stopAccessingSecurityScopedResource];
        }
    });
}

- (void)handleInitResources:(NSString *)modelName {
    BOOL hasModel = modelName && modelName.length > 0;

    NSArray *resourceFiles = @[
        @"resources/musiccoca/text_encoder.tflite",
        @"resources/musiccoca/pretrained_vector_quantizer.tflite",
        @"resources/musiccoca/audio_preprocessor.tflite",
        @"resources/musiccoca/music_encoder.tflite",
        @"resources/musiccoca/spm.model",
        @"resources/spectrostream/spectrostream_encoder.mlxfn",
        @"resources/spectrostream/decoder.safetensors",
        @"resources/spectrostream/encoder.safetensors",
        @"resources/spectrostream/quantizer.safetensors"
    ];

    NSMutableArray *allFiles = [NSMutableArray arrayWithArray:resourceFiles];
    if (hasModel) {
        NSString *prefix = [NSString stringWithFormat:@"models/%@", modelName];
        [allFiles addObject:[NSString stringWithFormat:@"%@/%@.mlxfn", prefix, modelName]];
        [allFiles addObject:[NSString stringWithFormat:@"%@/%@_state.safetensors", prefix, modelName]];
    }

    NSMutableArray *basenames = [NSMutableArray array];
    for (NSString *path in allFiles) {
        [basenames addObject:[path lastPathComponent]];
    }

    [self sendStateUpdate:@{
        @"onboardingFiles": basenames,
        @"resourcesProgress": @{
            @"status": @"downloading",
            @"percent": @(0.0),
            @"currentFile": basenames[0],
            @"currentIndex": @(0)
        }
    }];

    [MagentaModelDownloader initializeSharedResourcesWithProgress:^(double progress, NSString *status) {
        NSInteger resourceIndex = 0;
        NSString *currentBasename = [status lastPathComponent];
        for (NSInteger i = 0; i < resourceFiles.count; ++i) {
            if ([[resourceFiles[i] lastPathComponent] isEqualToString:currentBasename]) {
                resourceIndex = i;
                break;
            }
        }

        double scaledPercent = hasModel ? progress * 0.5 : progress;
        NSString *statusWithProgress = hasModel
            ? [NSString stringWithFormat:@"[1/2] Shared assets: %@", status]
            : status;

        [self sendStateUpdate:@{
            @"resourcesProgress": @{
                @"status": @"downloading",
                @"percent": @(scaledPercent),
                @"currentFile": currentBasename,
                @"currentIndex": @(resourceIndex),
                @"text": statusWithProgress
            }
        }];
    } completion:^(BOOL success, NSError *error) {
        if (!success) {
            [self sendStateUpdate:@{
                @"resourcesProgress": @{
                    @"status": @"error",
                    @"percent": @(0.0),
                    @"text": error.localizedDescription ?: @"Initialization Failed"
                }
            }];
            return;
        }

        if (hasModel) {
            [MagentaModelDownloader downloadModel:modelName progress:^(double progress, NSString *status) {
                double scaledPercent = 0.5 + (progress * 0.5);
                NSString *currentBasename = [status lastPathComponent];

                NSInteger modelIndex = 0;
                if ([currentBasename containsString:@"_state.safetensors"]) {
                    modelIndex = 1;
                }
                NSInteger overallIndex = 9 + modelIndex;

                [self sendStateUpdate:@{
                    @"resourcesProgress": @{
                        @"status": @"downloading",
                        @"percent": @(scaledPercent),
                        @"currentFile": currentBasename,
                        @"currentIndex": @(overallIndex),
                        @"text": [NSString stringWithFormat:@"[2/2] Model: %@", status]
                    }
                }];
            } completion:^(BOOL success, NSError *error) {
                if (success) {
                    // Re-initialize the C++ engine assets with the newly downloaded resources!
                    std::string resources = magentart::paths::get_resources_dir();
                    if (!self.engine->init_assets(resources.c_str())) {
                        NSLog(@"CONFABULATOR: Failed to re-initialize C++ assets after onboarding download");
                    } else {
                        NSLog(@"CONFABULATOR: Successfully initialized C++ assets after onboarding download");
                    }

                    [self sendStateUpdate:@{
                        @"resourcesProgress": @{
                            @"status": @"success",
                            @"percent": @(1.0),
                            @"text": @"Onboarding Completed!"
                        },
                        @"resourcesMissing": @NO
                    }];
                    [self handleListLocalModels];
                    [self handleSelectModel:modelName];
                } else {
                    [self sendStateUpdate:@{
                        @"resourcesProgress": @{
                            @"status": @"error",
                            @"percent": @(0.5),
                            @"text": error.localizedDescription ?: @"Model download failed"
                        }
                    }];
                }
            }];
        } else {
            std::string resources = magentart::paths::get_resources_dir();
            self.engine->init_assets(resources.c_str());

            [self sendStateUpdate:@{
                @"resourcesProgress": @{
                    @"status": @"success",
                    @"percent": @(1.0),
                    @"text": @"Initialization Completed!"
                },
                @"resourcesMissing": @NO
            }];
        }
    }];
}

- (void)dealloc {
    [_metricsTimer invalidate];
    [_agentServer stop];
}

@end
