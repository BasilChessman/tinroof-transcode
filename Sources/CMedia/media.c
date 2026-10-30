#include "media.h"
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/channel_layout.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

struct MCDecoder {
    AVFormatContext *fmt;
    int vidx, aidx;
    AVCodecContext *vctx, *actx;

    struct SwsContext *sws;
    int out_w, out_h;
    uint8_t *bgra;
    int bgra_linesize;
    size_t bgra_size;

    SwrContext *swr;
    int swr_in_rate;
    int swr_in_fmt;
    AVChannelLayout swr_in_layout;
    MCAudioMode swr_mode;
    int swr_out_rate;
    MCAudioMode audio_mode;
    int out_rate;
    float *pcm;
    int pcm_capacity; // in frames (stereo pairs)

    AVPacket *pkt;
    int pkt_pending;
    AVFrame *frame;
    int decode_video, decode_audio;
    int eof_sent;
    int video_done, audio_done;

    double start_time;
    double last_video_pts, last_audio_pts;
    char err[256];
};

static void set_err(MCDecoder *d, const char *what, int code) {
    char buf[128] = {0};
    if (code) av_strerror(code, buf, sizeof buf);
    snprintf(d->err, sizeof d->err, "%s%s%s", what, code ? ": " : "", buf);
}

static void copy_str(char *dst, size_t cap, const char *src) {
    if (!src) { dst[0] = 0; return; }
    snprintf(dst, cap, "%s", src);
}

static AVCodecContext *open_codec(MCDecoder *d, int index) {
    if (index < 0) return NULL;
    AVStream *st = d->fmt->streams[index];
    const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!codec) { set_err(d, "no decoder for stream", 0); return NULL; }
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx) return NULL;
    avcodec_parameters_to_context(ctx, st->codecpar);
    ctx->pkt_timebase = st->time_base;
    ctx->thread_count = 0; // automatic
    int r = avcodec_open2(ctx, codec, NULL);
    if (r < 0) { set_err(d, "cannot open decoder", r); avcodec_free_context(&ctx); return NULL; }
    return ctx;
}

MCDecoder *mc_open(const char *url, char *error, int error_len) {
    MCDecoder *d = calloc(1, sizeof *d);
    if (!d) return NULL;
    d->vidx = d->aidx = -1;
    d->out_rate = 48000;
    d->decode_video = d->decode_audio = 1;
    d->last_video_pts = d->last_audio_pts = -1;

    AVDictionary *opts = NULL;
    // Broadcast transport streams may announce audio late; probe generously.
    av_dict_set(&opts, "probesize", "50000000", 0);
    av_dict_set(&opts, "analyzeduration", "20000000", 0);
    int r = avformat_open_input(&d->fmt, url, NULL, &opts);
    av_dict_free(&opts);
    if (r < 0) {
        set_err(d, "cannot open", r);
        if (error) copy_str(error, (size_t)error_len, d->err);
        free(d);
        return NULL;
    }
    d->fmt->flags |= AVFMT_FLAG_GENPTS;
    r = avformat_find_stream_info(d->fmt, NULL);
    if (r < 0) {
        set_err(d, "cannot read stream info", r);
        if (error) copy_str(error, (size_t)error_len, d->err);
        avformat_close_input(&d->fmt);
        free(d);
        return NULL;
    }
    d->start_time = d->fmt->start_time != AV_NOPTS_VALUE ? (double)d->fmt->start_time / AV_TIME_BASE : 0.0;
    d->pkt = av_packet_alloc();
    d->frame = av_frame_alloc();

    int v = av_find_best_stream(d->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (v >= 0 && (d->fmt->streams[v]->disposition & AV_DISPOSITION_ATTACHED_PIC)) v = -1;
    int a = av_find_best_stream(d->fmt, AVMEDIA_TYPE_AUDIO, -1, v, NULL, 0);
    mc_select_streams(d, v < 0 ? -1 : v, a < 0 ? -1 : a);
    return d;
}

static void free_swr(MCDecoder *d) {
    if (d->swr) swr_free(&d->swr);
    av_channel_layout_uninit(&d->swr_in_layout);
}

void mc_close(MCDecoder *d) {
    if (!d) return;
    avcodec_free_context(&d->vctx);
    avcodec_free_context(&d->actx);
    if (d->sws) sws_freeContext(d->sws);
    free_swr(d);
    av_free(d->bgra);
    free(d->pcm);
    av_packet_free(&d->pkt);
    av_frame_free(&d->frame);
    avformat_close_input(&d->fmt);
    free(d);
}

const char *mc_last_error(MCDecoder *d) { return d ? d->err : "no decoder"; }

void mc_get_file_info(MCDecoder *d, MCFileInfo *info) {
    memset(info, 0, sizeof *info);
    copy_str(info->format_name, sizeof info->format_name, d->fmt->iformat->name);
    copy_str(info->format_long_name, sizeof info->format_long_name, d->fmt->iformat->long_name);
    info->duration = d->fmt->duration != AV_NOPTS_VALUE ? (double)d->fmt->duration / AV_TIME_BASE : 0;
    info->start_time = d->start_time;
    info->bit_rate = d->fmt->bit_rate;
    info->file_size = d->fmt->pb ? avio_size(d->fmt->pb) : -1;
    info->nb_streams = (int)d->fmt->nb_streams;
}

int mc_get_stream_info(MCDecoder *d, int index, MCStreamInfo *s) {
    if (index < 0 || index >= (int)d->fmt->nb_streams) return -1;
    memset(s, 0, sizeof *s);
    AVStream *st = d->fmt->streams[index];
    AVCodecParameters *p = st->codecpar;
    s->index = index;
    s->id = st->id;
    switch (p->codec_type) {
        case AVMEDIA_TYPE_VIDEO: s->type = MC_STREAM_VIDEO; break;
        case AVMEDIA_TYPE_AUDIO: s->type = MC_STREAM_AUDIO; break;
        case AVMEDIA_TYPE_SUBTITLE: s->type = MC_STREAM_SUBTITLE; break;
        default: s->type = MC_STREAM_OTHER; break;
    }
    const AVCodecDescriptor *desc = avcodec_descriptor_get(p->codec_id);
    copy_str(s->codec, sizeof s->codec, desc ? desc->name : "unknown");
    copy_str(s->codec_long, sizeof s->codec_long, desc ? desc->long_name : "unknown");
    copy_str(s->profile, sizeof s->profile, avcodec_profile_name(p->codec_id, p->profile));
    AVDictionaryEntry *lang = av_dict_get(st->metadata, "language", NULL, 0);
    copy_str(s->language, sizeof s->language, lang ? lang->value : "");
    s->width = p->width;
    s->height = p->height;
    AVRational sar = p->sample_aspect_ratio.num ? p->sample_aspect_ratio : st->sample_aspect_ratio;
    if (!sar.num || !sar.den) sar = (AVRational){1, 1};
    s->sar_num = sar.num; s->sar_den = sar.den;
    if (p->width && p->height) {
        av_reduce(&s->dar_num, &s->dar_den, (int64_t)p->width * sar.num, (int64_t)p->height * sar.den, 1024 * 1024);
    }
    AVRational fr = st->avg_frame_rate.num ? st->avg_frame_rate : st->r_frame_rate;
    s->fps = fr.den ? av_q2d(fr) : 0;
    s->variable_fps = st->avg_frame_rate.num && st->r_frame_rate.num && av_cmp_q(st->avg_frame_rate, st->r_frame_rate) != 0;
    switch (p->field_order) {
        case AV_FIELD_PROGRESSIVE: s->field_order = MC_FIELD_PROGRESSIVE; break;
        case AV_FIELD_TT: case AV_FIELD_TB: s->field_order = MC_FIELD_TOP_FIRST; break;
        case AV_FIELD_BB: case AV_FIELD_BT: s->field_order = MC_FIELD_BOTTOM_FIRST; break;
        default: s->field_order = MC_FIELD_UNKNOWN; break;
    }
    if (p->codec_type == AVMEDIA_TYPE_VIDEO)
        copy_str(s->pix_fmt, sizeof s->pix_fmt, av_get_pix_fmt_name((enum AVPixelFormat)p->format));
    s->sample_rate = p->sample_rate;
    s->channels = p->ch_layout.nb_channels;
    if (p->ch_layout.nb_channels) av_channel_layout_describe(&p->ch_layout, s->channel_layout, sizeof s->channel_layout);
    s->bit_rate = p->bit_rate;
    s->start_time = st->start_time != AV_NOPTS_VALUE ? st->start_time * av_q2d(st->time_base) : 0;
    s->duration = st->duration != AV_NOPTS_VALUE ? st->duration * av_q2d(st->time_base) : 0;
    s->is_attached_pic = (st->disposition & AV_DISPOSITION_ATTACHED_PIC) != 0;
    return 0;
}

int mc_select_streams(MCDecoder *d, int video_index, int audio_index) {
    int n = (int)d->fmt->nb_streams;
    if (video_index >= n || audio_index >= n) return -1;
    if (video_index != d->vidx || !d->vctx) {
        avcodec_free_context(&d->vctx);
        d->vidx = video_index;
        if (video_index >= 0 && d->fmt->streams[video_index]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO)
            d->vctx = open_codec(d, video_index);
        else d->vidx = -1;
    }
    if (audio_index != d->aidx || !d->actx) {
        avcodec_free_context(&d->actx);
        free_swr(d);
        d->aidx = audio_index;
        if (audio_index >= 0 && d->fmt->streams[audio_index]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO)
            d->actx = open_codec(d, audio_index);
        else d->aidx = -1;
    }
    for (int i = 0; i < n; i++)
        d->fmt->streams[i]->discard = (i == d->vidx || i == d->aidx) ? AVDISCARD_DEFAULT : AVDISCARD_ALL;
    return 0;
}

int mc_selected_video(MCDecoder *d) { return d->vctx ? d->vidx : -1; }
int mc_selected_audio(MCDecoder *d) { return d->actx ? d->aidx : -1; }

void mc_set_video_output_size(MCDecoder *d, int w, int h) { d->out_w = w; d->out_h = h; }
void mc_set_audio_mode(MCDecoder *d, MCAudioMode mode) { d->audio_mode = mode; }
void mc_set_audio_output_rate(MCDecoder *d, int rate) { d->out_rate = rate > 0 ? rate : 48000; }
void mc_set_decode_enabled(MCDecoder *d, int video, int audio) { d->decode_video = video; d->decode_audio = audio; }

int mc_seek(MCDecoder *d, double seconds) {
    int64_t ts = (int64_t)((seconds + d->start_time) * AV_TIME_BASE);
    int r = avformat_seek_file(d->fmt, -1, INT64_MIN, ts, ts, 0);
    if (r < 0) r = av_seek_frame(d->fmt, -1, ts, AVSEEK_FLAG_BACKWARD);
    if (r < 0) r = av_seek_frame(d->fmt, -1, ts, AVSEEK_FLAG_ANY);
    if (d->vctx) avcodec_flush_buffers(d->vctx);
    if (d->actx) avcodec_flush_buffers(d->actx);
    if (d->swr) { free_swr(d); }
    av_packet_unref(d->pkt);
    d->pkt_pending = 0;
    d->eof_sent = d->video_done = d->audio_done = 0;
    d->last_video_pts = d->last_audio_pts = -1;
    if (r < 0) set_err(d, "seek failed", r);
    return r < 0 ? r : 0;
}

static double frame_seconds(MCDecoder *d, AVFrame *f, AVStream *st) {
    int64_t ts = f->best_effort_timestamp;
    if (ts == AV_NOPTS_VALUE) ts = f->pts;
    if (ts == AV_NOPTS_VALUE) return -1;
    return ts * av_q2d(st->time_base) - d->start_time;
}

static int emit_video(MCDecoder *d, MCFrame *out) {
    AVFrame *f = d->frame;
    AVStream *st = d->fmt->streams[d->vidx];
    int w = d->out_w > 0 ? d->out_w : f->width;
    int h = d->out_h > 0 ? d->out_h : f->height;
    d->sws = sws_getCachedContext(d->sws, f->width, f->height, (enum AVPixelFormat)f->format,
                                  w, h, AV_PIX_FMT_BGRA, SWS_BICUBIC, NULL, NULL, NULL);
    if (!d->sws) { set_err(d, "cannot create scaler", 0); return -1; }
    int cs = f->colorspace;
    if (cs == AVCOL_SPC_UNSPECIFIED) cs = f->height >= 720 ? AVCOL_SPC_BT709 : AVCOL_SPC_SMPTE170M;
    const int *coefs = sws_getCoefficients(cs);
    int src_full = f->color_range == AVCOL_RANGE_JPEG;
    sws_setColorspaceDetails(d->sws, coefs, src_full, sws_getCoefficients(AVCOL_SPC_BT709), 1, 0, 1 << 16, 1 << 16);

    int linesize = FFALIGN(w * 4, 64);
    size_t need = (size_t)linesize * (size_t)h;
    if (need > d->bgra_size) {
        av_free(d->bgra);
        d->bgra = av_malloc(need);
        if (!d->bgra) { d->bgra_size = 0; return -1; }
        d->bgra_size = need;
    }
    d->bgra_linesize = linesize;
    uint8_t *dst[4] = {d->bgra, NULL, NULL, NULL};
    int dst_ls[4] = {linesize, 0, 0, 0};
    sws_scale(d->sws, (const uint8_t *const *)f->data, f->linesize, 0, f->height, dst, dst_ls);

    double pts = frame_seconds(d, f, st);
    double dur = f->duration > 0 ? f->duration * av_q2d(st->time_base) : 0;
    if (dur <= 0) {
        AVRational fr = st->avg_frame_rate.num ? st->avg_frame_rate : st->r_frame_rate;
        dur = fr.num ? 1.0 / av_q2d(fr) : 1.0 / 25.0;
    }
    if (pts < 0) pts = d->last_video_pts >= 0 ? d->last_video_pts + dur : 0;
    d->last_video_pts = pts;

    memset(out, 0, sizeof *out);
    out->type = MC_FRAME_VIDEO;
    out->pts = pts;
    out->duration = dur;
    out->key_frame = (f->flags & AV_FRAME_FLAG_KEY) != 0;
    out->interlaced = (f->flags & AV_FRAME_FLAG_INTERLACED) != 0;
    out->top_field_first = (f->flags & AV_FRAME_FLAG_TOP_FIELD_FIRST) != 0;
    out->pixels = d->bgra;
    out->linesize = linesize;
    out->width = w;
    out->height = h;
    return 1;
}

static int chan(const AVChannelLayout *l, enum AVChannel c) {
    return av_channel_layout_index_from_channel(l, c);
}

// Builds a 2 x in_ch matrix for the channel-isolation modes.
static void build_matrix(const AVChannelLayout *in, MCAudioMode mode, double *m) {
    int n = in->nb_channels;
    memset(m, 0, sizeof(double) * 2 * (size_t)n);
    int L = chan(in, AV_CHAN_FRONT_LEFT), R = chan(in, AV_CHAN_FRONT_RIGHT), C = chan(in, AV_CHAN_FRONT_CENTER);
    int LS = chan(in, AV_CHAN_SIDE_LEFT), RS = chan(in, AV_CHAN_SIDE_RIGHT);
    if (LS < 0) LS = chan(in, AV_CHAN_BACK_LEFT);
    if (RS < 0) RS = chan(in, AV_CHAN_BACK_RIGHT);
    int S = chan(in, AV_CHAN_BACK_CENTER);
    int LFE = chan(in, AV_CHAN_LOW_FREQUENCY);
    if (n == 1) { m[0] = 1; m[n] = 1; return; }
    double *l = m, *r = m + n;
    switch (mode) {
        case MC_AUDIO_FRONT_MIX: {
            double g = C >= 0 && (L >= 0 || R >= 0) ? 1.0 / (1.0 + M_SQRT1_2) : 1.0;
            if (L >= 0) l[L] = g;
            if (R >= 0) r[R] = g;
            if (C >= 0) { double c = (L >= 0 || R >= 0) ? M_SQRT1_2 * g : 1.0; l[C] = c; r[C] = c; }
            break;
        }
        case MC_AUDIO_LR_ONLY:
            if (L >= 0 || R >= 0) { if (L >= 0) l[L] = 1; if (R >= 0) r[R] = 1; }
            else if (C >= 0) { l[C] = 1; r[C] = 1; }
            break;
        case MC_AUDIO_CENTER_ONLY:
            if (C >= 0) { l[C] = 1; r[C] = 1; }
            else { if (L >= 0) { l[L] = 0.5; r[L] = 0.5; } if (R >= 0) { l[R] = 0.5; r[R] = 0.5; } }
            break;
        case MC_AUDIO_SURROUNDS_ONLY:
            if (LS >= 0 || RS >= 0) { if (LS >= 0) l[LS] = 1; if (RS >= 0) r[RS] = 1; }
            else if (S >= 0) { l[S] = 1; r[S] = 1; }
            break;
        case MC_AUDIO_LFE_ONLY:
            if (LFE >= 0) { l[LFE] = 1; r[LFE] = 1; }
            break;
        default: break;
    }
}

static int ensure_swr(MCDecoder *d, AVFrame *f) {
    if (d->swr && d->swr_in_rate == f->sample_rate && d->swr_in_fmt == f->format &&
        !av_channel_layout_compare(&d->swr_in_layout, &f->ch_layout) && d->swr_mode == d->audio_mode &&
        d->swr_out_rate == d->out_rate)
        return 0;
    free_swr(d);
    AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
    AVChannelLayout in;
    if (f->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC) av_channel_layout_default(&in, f->ch_layout.nb_channels);
    else av_channel_layout_copy(&in, &f->ch_layout);
    int r = swr_alloc_set_opts2(&d->swr, &stereo, AV_SAMPLE_FMT_FLT, d->out_rate,
                                &in, (enum AVSampleFormat)f->format, f->sample_rate, 0, NULL);
    if (r < 0) { av_channel_layout_uninit(&in); set_err(d, "cannot create resampler", r); return r; }
    int custom = in.nb_channels > 2 || d->audio_mode == MC_AUDIO_CENTER_ONLY;
    if (d->audio_mode == MC_AUDIO_SURROUND && in.nb_channels > 2) {
        av_opt_set_int(d->swr, "matrix_encoding", AV_MATRIX_ENCODING_DOLBY, 0);
    } else if (d->audio_mode != MC_AUDIO_STEREO_MIX && d->audio_mode != MC_AUDIO_SURROUND && custom) {
        double *m = calloc(2 * (size_t)in.nb_channels, sizeof(double));
        build_matrix(&in, d->audio_mode, m);
        swr_set_matrix(d->swr, m, in.nb_channels);
        free(m);
    }
    r = swr_init(d->swr);
    if (r < 0) { av_channel_layout_uninit(&in); swr_free(&d->swr); set_err(d, "cannot init resampler", r); return r; }
    av_channel_layout_copy(&d->swr_in_layout, &f->ch_layout);
    av_channel_layout_uninit(&in);
    d->swr_in_rate = f->sample_rate;
    d->swr_in_fmt = f->format;
    d->swr_mode = d->audio_mode;
    d->swr_out_rate = d->out_rate;
    return 0;
}

static int emit_audio(MCDecoder *d, MCFrame *out) {
    AVFrame *f = d->frame;
    AVStream *st = d->fmt->streams[d->aidx];
    if (ensure_swr(d, f) < 0) return -1;
    int max_out = swr_get_out_samples(d->swr, f->nb_samples);
    if (max_out <= 0) max_out = f->nb_samples * 2 + 256;
    if (max_out > d->pcm_capacity) {
        float *p = realloc(d->pcm, sizeof(float) * 2 * (size_t)max_out);
        if (!p) return -1;
        d->pcm = p;
        d->pcm_capacity = max_out;
    }
    uint8_t *dst[1] = {(uint8_t *)d->pcm};
    int n = swr_convert(d->swr, dst, max_out, (const uint8_t **)f->extended_data, f->nb_samples);
    if (n < 0) { set_err(d, "resample failed", n); return -1; }
    double pts = frame_seconds(d, f, st);
    double dur = (double)n / d->out_rate;
    if (pts < 0) pts = d->last_audio_pts >= 0 ? d->last_audio_pts : 0;
    d->last_audio_pts = pts + dur;
    memset(out, 0, sizeof *out);
    out->type = MC_FRAME_AUDIO;
    out->pts = pts;
    out->duration = dur;
    out->samples = d->pcm;
    out->nb_samples = n;
    out->sample_rate = d->out_rate;
    return 1;
}

static int send_current_packet(MCDecoder *d) {
    AVCodecContext *ctx = NULL;
    if (d->pkt->stream_index == d->vidx && d->vctx && d->decode_video) ctx = d->vctx;
    else if (d->pkt->stream_index == d->aidx && d->actx && d->decode_audio) ctx = d->actx;
    if (!ctx) { av_packet_unref(d->pkt); return 0; }
    int r = avcodec_send_packet(ctx, d->pkt);
    if (r == AVERROR(EAGAIN)) { d->pkt_pending = 1; return 1; }
    av_packet_unref(d->pkt); // other errors: drop corrupt packet and continue
    return 0;
}

int mc_decode_next(MCDecoder *d, MCFrame *out) {
    if (!d->vctx && !d->actx) return 0;
    for (;;) {
        if (d->vctx && d->decode_video && !d->video_done) {
            int r = avcodec_receive_frame(d->vctx, d->frame);
            if (r == 0) { int e = emit_video(d, out); av_frame_unref(d->frame); if (e != 0) return e; }
            else if (r == AVERROR_EOF) d->video_done = 1;
        }
        if (d->actx && d->decode_audio && !d->audio_done) {
            int r = avcodec_receive_frame(d->actx, d->frame);
            if (r == 0) { int e = emit_audio(d, out); av_frame_unref(d->frame); if (e != 0) return e; }
            else if (r == AVERROR_EOF) d->audio_done = 1;
        }
        if (d->eof_sent) {
            int vdone = !d->vctx || !d->decode_video || d->video_done;
            int adone = !d->actx || !d->decode_audio || d->audio_done;
            if (vdone && adone) return 0;
            continue;
        }
        if (d->pkt_pending) {
            d->pkt_pending = 0;
            if (send_current_packet(d)) continue;
        }
        int r = av_read_frame(d->fmt, d->pkt);
        if (r < 0) {
            // End of file or unrecoverable read error: drain decoders.
            if (d->vctx) avcodec_send_packet(d->vctx, NULL);
            if (d->actx) avcodec_send_packet(d->actx, NULL);
            d->eof_sent = 1;
            continue;
        }
        send_current_packet(d);
    }
}

static int append(double **arr, int *count, int *cap, double v) {
    if (*count == *cap) {
        int nc = *cap ? *cap * 2 : 1024;
        double *p = realloc(*arr, sizeof(double) * (size_t)nc);
        if (!p) return -1;
        *arr = p;
        *cap = nc;
    }
    (*arr)[(*count)++] = v;
    return 0;
}

int mc_build_index(const char *url, int stream_index, MCIndex *out, MCProgressCallback progress, void *ctx) {
    memset(out, 0, sizeof *out);
    AVFormatContext *fmt = NULL;
    AVDictionary *opts = NULL;
    av_dict_set(&opts, "probesize", "50000000", 0);
    av_dict_set(&opts, "analyzeduration", "20000000", 0);
    int r = avformat_open_input(&fmt, url, NULL, &opts);
    av_dict_free(&opts);
    if (r < 0) return r;
    r = avformat_find_stream_info(fmt, NULL);
    if (r < 0 || stream_index < 0 || stream_index >= (int)fmt->nb_streams) {
        avformat_close_input(&fmt);
        return r < 0 ? r : AVERROR(EINVAL);
    }
    for (unsigned i = 0; i < fmt->nb_streams; i++)
        fmt->streams[i]->discard = (int)i == stream_index ? AVDISCARD_DEFAULT : AVDISCARD_ALL;
    AVStream *st = fmt->streams[stream_index];
    double tb = av_q2d(st->time_base);
    double start = fmt->start_time != AV_NOPTS_VALUE ? (double)fmt->start_time / AV_TIME_BASE : 0;
    int64_t size = fmt->pb ? avio_size(fmt->pb) : -1;
    AVPacket *pkt = av_packet_alloc();
    int kcap = 0, bcap = 0;
    double prev = -1e18, max_t = 0;
    int64_t n = 0;
    while (av_read_frame(fmt, pkt) >= 0) {
        if (pkt->stream_index == stream_index) {
            int64_t ts = pkt->pts != AV_NOPTS_VALUE ? pkt->pts : pkt->dts;
            int64_t dts = pkt->dts != AV_NOPTS_VALUE ? pkt->dts : ts;
            if (pkt->flags & AV_PKT_FLAG_CORRUPT) out->corrupt_packets++;
            if (ts != AV_NOPTS_VALUE) {
                double t = ts * tb - start;
                if ((pkt->flags & AV_PKT_FLAG_KEY) && append(&out->keyframes, &out->keyframe_count, &kcap, t) < 0) break;
                if (t > max_t) max_t = t;
            }
            if (dts != AV_NOPTS_VALUE) {
                double t = dts * tb - start;
                // A backwards jump or a gap over two seconds is a timecode break.
                if (prev > -1e17 && (t < prev - 0.5 || t > prev + 2.0))
                    append(&out->breaks, &out->break_count, &bcap, t);
                prev = t;
            }
            n++;
            if (progress && (n & 255) == 0 && size > 0) {
                double frac = (double)avio_tell(fmt->pb) / (double)size;
                if (progress(frac, ctx)) { av_packet_unref(pkt); break; }
            }
        }
        av_packet_unref(pkt);
    }
    out->packets = n;
    out->duration = max_t;
    av_packet_free(&pkt);
    avformat_close_input(&fmt);
    if (progress) progress(1.0, ctx);
    return 0;
}

void mc_free_index(MCIndex *index) {
    free(index->keyframes);
    free(index->breaks);
    memset(index, 0, sizeof *index);
}
