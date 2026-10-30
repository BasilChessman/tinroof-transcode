// Minimal C interface over FFmpeg used by the Swift layers.
// The public header deliberately avoids libav types so Swift sees plain C.
#ifndef CMEDIA_MEDIA_H
#define CMEDIA_MEDIA_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    MC_STREAM_VIDEO = 0,
    MC_STREAM_AUDIO = 1,
    MC_STREAM_SUBTITLE = 2,
    MC_STREAM_OTHER = 3,
} MCStreamType;

typedef enum {
    MC_FIELD_UNKNOWN = 0,
    MC_FIELD_PROGRESSIVE = 1,
    MC_FIELD_TOP_FIRST = 2,
    MC_FIELD_BOTTOM_FIRST = 3,
} MCFieldOrder;

/// Two-channel rendering of multichannel (AC3 / 5.1) audio.
typedef enum {
    MC_AUDIO_STEREO_MIX = 0,   // standard downmix using stream mix levels, no LFE
    MC_AUDIO_FRONT_MIX = 1,    // L, R, C only (surrounds dropped)
    MC_AUDIO_SURROUND = 2,     // Dolby Surround / Pro Logic compatible matrix
    MC_AUDIO_LR_ONLY = 3,      // L and R channels only (C if no L/R)
    MC_AUDIO_CENTER_ONLY = 4,  // centre channel (mono mix of L/R if missing)
    MC_AUDIO_SURROUNDS_ONLY = 5, // LS / RS (or S) channels
    MC_AUDIO_LFE_ONLY = 6,     // LFE channel
} MCAudioMode;

typedef struct {
    char format_name[64];
    char format_long_name[128];
    double duration;      // seconds, <= 0 if unknown
    double start_time;    // seconds
    int64_t bit_rate;     // bits/s, 0 if unknown
    int64_t file_size;    // bytes, -1 if unknown
    int nb_streams;
} MCFileInfo;

typedef struct {
    int index;
    MCStreamType type;
    int id;                    // PID for TS, start code for PS, track id otherwise
    char codec[64];
    char codec_long[128];
    char profile[64];
    char language[16];
    int width, height;
    int sar_num, sar_den;      // sample aspect ratio
    int dar_num, dar_den;      // display aspect ratio
    double fps;                // average frame rate, 0 if unknown
    int variable_fps;          // r_frame_rate != avg_frame_rate
    MCFieldOrder field_order;
    char pix_fmt[32];
    int sample_rate;
    int channels;
    char channel_layout[64];
    int64_t bit_rate;
    double start_time;
    double duration;
    int is_attached_pic;
} MCStreamInfo;

typedef enum {
    MC_FRAME_NONE = 0,
    MC_FRAME_VIDEO = 1,
    MC_FRAME_AUDIO = 2,
} MCFrameType;

typedef struct {
    MCFrameType type;
    double pts;                // seconds from media start (file start_time subtracted)
    double duration;           // seconds
    int key_frame;
    int interlaced;
    int top_field_first;
    // video (BGRA, owned by the decoder, valid until the next decode call)
    const uint8_t *pixels;
    int linesize;
    int width, height;
    // audio (interleaved float stereo, owned by the decoder)
    const float *samples;
    int nb_samples;
    int sample_rate;
} MCFrame;

typedef struct MCDecoder MCDecoder;

/// Progress callback for long scans. Return non-zero to cancel.
typedef int (*MCProgressCallback)(double fraction, void *context);

/// Open a file or URL (anything libavformat accepts, including `concat:a|b`).
MCDecoder *mc_open(const char *url, char *error, int error_len);
void mc_close(MCDecoder *dec);

void mc_get_file_info(MCDecoder *dec, MCFileInfo *info);
int mc_get_stream_info(MCDecoder *dec, int index, MCStreamInfo *info);

/// Select active streams (-1 to disable). Returns 0 on success.
int mc_select_streams(MCDecoder *dec, int video_index, int audio_index);
int mc_selected_video(MCDecoder *dec);
int mc_selected_audio(MCDecoder *dec);

/// Size of BGRA output frames; 0 x 0 uses the coded size.
void mc_set_video_output_size(MCDecoder *dec, int width, int height);
void mc_set_audio_mode(MCDecoder *dec, MCAudioMode mode);
/// Output audio sample rate (default 48000).
void mc_set_audio_output_rate(MCDecoder *dec, int rate);
/// Disable decoding of a stream type temporarily (e.g. audio during scrubbing).
void mc_set_decode_enabled(MCDecoder *dec, int video, int audio);

/// Seek to the keyframe at or before `seconds` and flush decoders.
int mc_seek(MCDecoder *dec, double seconds);

/// Decode the next frame from the selected streams.
/// Returns 1 if `frame` was filled, 0 at end of stream, < 0 on error.
int mc_decode_next(MCDecoder *dec, MCFrame *frame);

/// Last error message.
const char *mc_last_error(MCDecoder *dec);

/// Index scan: reads every packet of `stream_index` without decoding.
/// Returns key-frame times and timestamp discontinuities (in seconds from start).
typedef struct {
    double *keyframes;
    int keyframe_count;
    double *breaks;            // positions where packet timestamps jump
    int break_count;
    double duration;           // measured duration of the stream
    int64_t packets;
    int64_t corrupt_packets;
} MCIndex;

int mc_build_index(const char *url, int stream_index, MCIndex *out,
                   MCProgressCallback progress, void *context);
void mc_free_index(MCIndex *index);

#ifdef __cplusplus
}
#endif

#endif
