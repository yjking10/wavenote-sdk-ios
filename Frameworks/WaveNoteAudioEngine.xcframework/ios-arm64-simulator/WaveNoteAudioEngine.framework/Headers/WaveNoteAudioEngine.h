// Public Objective-C umbrella header for WaveNoteAudioEngine.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, WaveNoteAudioEnginePlaybackState) {
    WaveNoteAudioEnginePlaybackStateIdle,
    WaveNoteAudioEnginePlaybackStatePreparing,
    WaveNoteAudioEnginePlaybackStateReady,
    WaveNoteAudioEnginePlaybackStatePlaying,
    WaveNoteAudioEnginePlaybackStatePaused,
    WaveNoteAudioEnginePlaybackStateStopped,
    WaveNoteAudioEnginePlaybackStateCompleted,
    WaveNoteAudioEnginePlaybackStateReleased,
    WaveNoteAudioEnginePlaybackStateFailed,
};

typedef NS_ENUM(NSInteger, WaveNoteAudioEngineNoiseSuppressionLevel) {
    WaveNoteAudioEngineNoiseSuppressionLevelOff = 0,
    WaveNoteAudioEngineNoiseSuppressionLevelLight = 12,
    WaveNoteAudioEngineNoiseSuppressionLevelBalanced = 20,
    WaveNoteAudioEngineNoiseSuppressionLevelStrong = 30,
};

typedef NS_ENUM(NSInteger, WaveNoteAudioEngineRepeatMode) {
    WaveNoteAudioEngineRepeatModeOff,
    WaveNoteAudioEngineRepeatModeOne,
};

@class WaveNoteAudioEnginePlayer;

/// Receive state, timing, interruption, noise-suppression, and failure events.
/// All callbacks arrive on the main thread.
@protocol WaveNoteAudioEnginePlayerDelegate <NSObject>
@optional
/// Reports a lifecycle state transition.
- (void)audioEnginePlayer:(WaveNoteAudioEnginePlayer *)player didChangeState:(WaveNoteAudioEnginePlaybackState)state;
/// Reports current play position and the prepared file's duration, in milliseconds.
- (void)audioEnginePlayer:(WaveNoteAudioEnginePlayer *)player didUpdatePosition:(int64_t)positionMilliseconds durationMilliseconds:(int64_t)durationMilliseconds;
/// Reports normal completion, except when repeat-one has been selected.
- (void)audioEnginePlayerDidComplete:(WaveNoteAudioEnginePlayer *)player;
/// Reports an audio-session interruption, route change, or playback preemption.
- (void)audioEnginePlayer:(WaveNoteAudioEnginePlayer *)player didInterruptWithReason:(NSString *)reason;
/// Reports asynchronous setup and readiness of the selected suppression level.
- (void)audioEnginePlayer:(WaveNoteAudioEnginePlayer *)player didUpdateNoiseSuppression:(WaveNoteAudioEngineNoiseSuppressionLevel)level ready:(BOOL)ready;
/// Reports that suppression was bypassed and normal playback continues.
- (void)audioEnginePlayer:(WaveNoteAudioEnginePlayer *)player didBypassNoiseSuppressionWithReason:(NSString *)reason;
/// Reports a non-recoverable playback error.
- (void)audioEnginePlayer:(WaveNoteAudioEnginePlayer *)player didFailWithError:(NSError *)error;
@end

/// Main-thread player for a single local audio file.
///
/// Set `delegate`, call `prepareWithFileURL:completion:`, then call `playWithError:`.
/// Call `close` at the end of the object's lifecycle; a closed instance cannot be reused.
@interface WaveNoteAudioEnginePlayer : NSObject
@property (nonatomic, weak, nullable) id<WaveNoteAudioEnginePlayerDelegate> delegate;
@property (nonatomic, readonly) WaveNoteAudioEnginePlaybackState state;
- (instancetype)init;
/// Opens a readable local audio file and prepares its audio session. Completion is on the main thread.
- (void)prepareWithFileURL:(NSURL *)fileURL completion:(void (^)(NSError * _Nullable error))completion;
/// Starts or resumes playback. Returns `NO` and assigns `error` when not prepared or already closed.
- (BOOL)playWithError:(NSError * _Nullable * _Nullable)error;
/// Pauses playback, retaining the current position. Has no effect unless currently playing.
- (void)pause;
/// Stops playback and resets the next play position to the beginning.
- (void)stop;
/// Seeks to a non-negative offset from the beginning of the prepared file, expressed in milliseconds.
- (BOOL)seekToMilliseconds:(int64_t)milliseconds error:(NSError * _Nullable * _Nullable)error;
/// Sets output volume in the inclusive range 0.0 through 1.0.
- (BOOL)setVolume:(float)value error:(NSError * _Nullable * _Nullable)error;
/// Sets playback speed in the inclusive range 0.5 through 2.0.
- (BOOL)setRate:(float)value error:(NSError * _Nullable * _Nullable)error;
/// Selects no repeat or repeat of the current item.
- (void)setRepeatMode:(WaveNoteAudioEngineRepeatMode)mode;
/// Enables or disables streaming noise suppression. Observe the delegate for asynchronous readiness.
- (void)setNoiseSuppressionLevel:(WaveNoteAudioEngineNoiseSuppressionLevel)level;
/// Releases the audio session and resources. The receiver cannot be prepared again afterwards.
- (void)close;
@end

/// Extracts normalized RMS waveform values from local audio files.
@interface WaveNoteAudioEngineWaveformExtractor : NSObject
- (instancetype)init;
/// Returns `sampleCount` normalized float values (boxed as `NSNumber`) through completion.
/// `sampleCount` must be 1...100000; progress and completion are called on the main thread.
- (void)extractWaveformFromFileURL:(NSURL *)fileURL
                       sampleCount:(NSInteger)sampleCount
                          progress:(void (^)(double progress))progress
                        completion:(void (^)(NSArray<NSNumber *> * _Nullable values, NSError * _Nullable error))completion;
/// Returns one normalized float value per requested audio second density (boxed as `NSNumber`).
/// The result has `ceil(duration * samplesPerSecond)` values, at least one and at most 100000.
/// `samplesPerSecond` must be positive; progress and completion are called on the main thread.
- (void)extractWaveformFromFileURL:(NSURL *)fileURL
                  samplesPerSecond:(NSInteger)samplesPerSecond
                          progress:(void (^)(double progress))progress
                        completion:(void (^)(NSArray<NSNumber *> * _Nullable values, NSError * _Nullable error))completion;
@end

/// Writes a denoised WAV file from a local input file.
@interface WaveNoteAudioEngineDenoiser : NSObject
- (instancetype)init;
/// Writes a 48 kHz mono 16-bit PCM WAV file at `outputURL`.
/// The output URL must end in `.wav`, be local, and not already exist. Progress and completion are on the main thread.
- (void)denoiseFileAtURL:(NSURL *)inputURL
               outputURL:(NSURL *)outputURL
                   level:(WaveNoteAudioEngineNoiseSuppressionLevel)level
                progress:(void (^)(double progress))progress
              completion:(void (^)(NSError * _Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
