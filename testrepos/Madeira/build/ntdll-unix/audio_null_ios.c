/*
 * audio_null_ios.c — minimal Wine audio "null" driver for iOS Madeira.
 *
 * Wine's mmdevapi loads a `wine<name>.drv` PE plus a unix-side function
 * table (37 entries). On Linux/macOS the unix table is a separate .so.
 * On iOS we statically link the table into Madeira.app — this file is
 * that table for "ios" / "coreaudio".
 *
 * Behaviour: ONE fake render endpoint, accepts buffer submissions and
 * discards, advances IAudioClock at real-time based on
 * mach_absolute_time. Enough to let FMOD's clock-driven timing
 * advance (rhythm games like Thumper gate splash→title on intro
 * music completing — this is what makes that work).
 *
 * 2026-07-05 TIER-2: REAL AUDIO OUTPUT via a RemoteIO AudioUnit.
 * WASAPI render semantics map onto a lock-free ring buffer:
 *   get_render_buffer  -> contiguous scratch pointer
 *   release_render_buffer -> copy scratch into the ring, advance write_pos
 *   RemoteIO render callback (Core Audio real-time thread — touches ONLY
 *   the ring + atomics, never Wine) -> copy ring to hardware, advance
 *   play_pos; underrun plays silence
 *   get_current_padding -> write_pos - play_pos
 *   get_position        -> play_pos (frames actually consumed)
 *   timer_loop          -> Wine thread; signals the client event per period
 * If AudioUnit setup fails (no session, etc.) the driver degrades to the
 * Tier-1 wall-clock null behaviour so game timing never breaks.
 * AVAudioSession activation happens app-side (WineProcessBridge.m).
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <mach/mach_time.h>
#include <unistd.h>
#include <AudioToolbox/AudioToolbox.h>

/* Struct/enum mirrors from wine/dlls/mmdevapi/unixlib.h. Repeating the
 * essential layout here avoids include-path drama with Wine's COM
 * headers, which pull in <objbase.h>/<audioclient.h>. We only need the
 * struct fields the unix-call dispatch touches. */

typedef int NTSTATUS;
typedef uint16_t WCHAR;
typedef int32_t HRESULT;
typedef uint32_t DWORD;
typedef uint32_t UINT32;
typedef uint64_t UINT64;
typedef uint64_t UINT_PTR;
typedef uint32_t UINT;
typedef int BOOL;
typedef uint8_t BYTE;
typedef int64_t REFERENCE_TIME;
typedef void *HANDLE;
typedef uint16_t WORD;
typedef uint64_t stream_handle;
typedef int EDataFlow;

#define STATUS_SUCCESS 0
#define S_OK 0
#define E_OUTOFMEMORY ((HRESULT)0x8007000EL)
#define AUDCLNT_E_NOT_INITIALIZED ((HRESULT)0x88890001L)
#define S_FALSE 1
#define E_FAIL 0x80004005L
#define AUDCLNT_E_NOT_INITIALIZED 0x88890001L

#define eRender 0
#define eCapture 1

enum driver_priority {
    Priority_Unavailable = 0,
    Priority_Low,
    Priority_Neutral,
    Priority_Preferred
};

struct endpoint {
    unsigned int name;
    unsigned int device;
};

struct main_loop_params { HANDLE event; };

struct get_endpoint_ids_params {
    EDataFlow flow;
    struct endpoint *endpoints;
    unsigned int size;
    HRESULT result;
    unsigned int num;
    unsigned int default_idx;
};

struct WAVEFORMATEX_stub {
    WORD wFormatTag;
    WORD nChannels;
    DWORD nSamplesPerSec;
    DWORD nAvgBytesPerSec;
    WORD nBlockAlign;
    WORD wBitsPerSample;
    WORD cbSize;
};

struct create_stream_params {
    const WCHAR *name;
    const char *device;
    EDataFlow flow;
    int share;
    DWORD flags;
    REFERENCE_TIME duration;
    REFERENCE_TIME period;
    const struct WAVEFORMATEX_stub *fmt;
    HRESULT result;
    UINT32 *channel_count;
    stream_handle *stream;
};

struct stream_handle_params { stream_handle stream; HRESULT result; };
struct timer_loop_params { stream_handle stream; };
struct stream_handle_only { stream_handle stream; };

struct release_stream_params {
    stream_handle stream;
    HANDLE timer_thread;
    HRESULT result;
};

struct get_render_buffer_params {
    stream_handle stream;
    UINT32 frames;
    HRESULT result;
    BYTE **data;
};

struct release_render_buffer_params {
    stream_handle stream;
    UINT32 written_frames;
    UINT flags;
    HRESULT result;
};

struct get_capture_buffer_params {
    stream_handle stream;
    HRESULT result;
    BYTE **data;
    UINT32 *frames;
    UINT *flags;
    UINT64 *devpos;
    UINT64 *qpcpos;
};

struct release_capture_buffer_params {
    stream_handle stream;
    UINT32 done;
    HRESULT result;
};

struct is_format_supported_params {
    const char *device;
    EDataFlow flow;
    int share;
    const struct WAVEFORMATEX_stub *fmt_in;
    HRESULT result;
};

struct get_mix_format_params {
    const char *device;
    EDataFlow flow;
    void *fmt;          /* WAVEFORMATEXTENSIBLE */
    HRESULT result;
};

struct get_device_period_params {
    const char *device;
    EDataFlow flow;
    HRESULT result;
    REFERENCE_TIME *def_period;
    REFERENCE_TIME *min_period;
};

struct get_buffer_size_params {
    stream_handle stream;
    HRESULT result;
    UINT32 *frames;
};

struct get_latency_params {
    stream_handle stream;
    HRESULT result;
    REFERENCE_TIME *latency;
};

struct get_current_padding_params {
    stream_handle stream;
    HRESULT result;
    UINT32 *padding;
};

struct get_next_packet_size_params {
    stream_handle stream;
    HRESULT result;
    UINT32 *frames;
};

struct get_frequency_params {
    stream_handle stream;
    HRESULT result;
    UINT64 *freq;
};

struct get_position_params {
    stream_handle stream;
    BOOL device;
    HRESULT result;
    UINT64 *pos;
    UINT64 *qpctime;
};

struct set_volumes_params {
    stream_handle stream;
    float master_volume;
    const float *volumes;
    const float *session_volumes;
};

struct set_event_handle_params {
    stream_handle stream;
    HANDLE event;
    HRESULT result;
};

struct set_sample_rate_params {
    stream_handle stream;
    float rate;
    HRESULT result;
};

struct test_connect_params {
    const WCHAR *name;
    enum driver_priority priority;
};

struct is_started_params {
    stream_handle stream;
    HRESULT result;
};

struct get_prop_value_params {
    const char *device;
    EDataFlow flow;
    const void *guid;
    const void *prop;
    HRESULT result;
    void *value;
    void *buffer;
    unsigned int *buffer_size;
};

/* ---------------------------------------------------------------- */

#define IOS_AUDIO_SAMPLE_RATE 48000u
#define IOS_AUDIO_CHANNELS 2u
#define IOS_AUDIO_BITS 16u
#define IOS_AUDIO_FRAME_BYTES ((IOS_AUDIO_CHANNELS * IOS_AUDIO_BITS) / 8u) /* 4 */
#define IOS_AUDIO_BUFFER_FRAMES 1024u  /* ~21 ms at 48 kHz */
#define IOS_AUDIO_BUFFER_BYTES (IOS_AUDIO_BUFFER_FRAMES * IOS_AUDIO_FRAME_BYTES)

/* The "device" Wine probes by name. mmdevapi stores it on the endpoint
 * struct and passes it back as `const char *device` in many calls. */
static const char IOS_DEVICE_NAME[] = "ios-null";

/* One global stream state — single render endpoint, single stream. FMOD
 * typically creates one shared-mode render stream; if a game opens a
 * second concurrent stream we'd need a table. Not worried about that
 * for the Tier-1 silent driver. */
struct ios_stream {
    int valid;
    int started;
    uint64_t start_mach;        /* mach_absolute_time() at start() (null-mode clock) */
    uint64_t accumulated_frames; /* null-mode: frames "played" before last stop */
    UINT32 sample_rate;
    UINT32 channels;
    UINT32 frame_bytes;          /* nBlockAlign of the stream format */
    UINT32 buffer_frames;        /* ring capacity in frames */
    BYTE *render_scratch;        /* contiguous area handed to GetBuffer */
    UINT32 scratch_frames;       /* scratch capacity */
    UINT32 pending_frames;       /* frames handed out, awaiting release */
    HANDLE event;
    /* Tier-2 real output */
    AudioUnit au;                /* RemoteIO; NULL = null-mode fallback */
    int au_running;
    BYTE *ring;
    _Atomic uint64_t write_pos;  /* frames produced by the game (monotonic) */
    _Atomic uint64_t play_pos;   /* frames consumed by the RT callback */
};

/* ml739: one stream object per client, mirroring Wine's CoreAudio driver.
 *
 * This was a documented singleton -- see the comment on struct ios_stream --
 * and ordinary WASAPI use breaks it: a title that plays a cutscene opens a
 * second concurrent render client (48k/2ch float32) while its main audio
 * client (48k/2ch PCM16) is still live. Both were handed the SAME handle, so
 * creating the second tore down the first's AudioUnit, set_event_handle
 * overwrote the first client's event -- after which it was never signalled
 * again -- and both shared one ring, one padding counter and one play
 * position, with two audio_client_timer threads driving them. The audible
 * result was a silent cutscene; the functional result was a source queue that
 * never drained, so the video never reported completion.
 *
 * The registry exists only for handle validation and process-detach cleanup.
 * It is never touched from the RemoteIO callback, which reaches its stream
 * through inputProcRefCon. */
#define IOS_MAX_STREAMS 16
static struct ios_stream *g_streams[IOS_MAX_STREAMS];
static pthread_mutex_t g_streams_lock;   /* ml739: init at process_attach */

static struct ios_stream *stream_from_handle(stream_handle h)
{
    struct ios_stream *s = (struct ios_stream *)(uintptr_t)h;
    int i, ok = 0;
    if (!s) return NULL;
    pthread_mutex_lock(&g_streams_lock);
    for (i = 0; i < IOS_MAX_STREAMS; i++) if (g_streams[i] == s) { ok = 1; break; }
    pthread_mutex_unlock(&g_streams_lock);
    if (!ok) {
        static int moaned;
        if (moaned++ < 8)
            fprintf(stderr, "[ios-astream] ml739 STALE handle %p -- ignoring\n", (void *)s);
        return NULL;
    }
    return s;
}

static int stream_register(struct ios_stream *s)
{
    int i, n = 0;
    pthread_mutex_lock(&g_streams_lock);
    for (i = 0; i < IOS_MAX_STREAMS; i++) if (g_streams[i]) n++;
    for (i = 0; i < IOS_MAX_STREAMS; i++) if (!g_streams[i]) { g_streams[i] = s; break; }
    pthread_mutex_unlock(&g_streams_lock);
    if (i == IOS_MAX_STREAMS) return -1;
    fprintf(stderr, "[ios-astream] ml739 CREATE stream=%p (%d now live)\n", (void *)s, n + 1);
    return 0;
}

static void stream_unregister(struct ios_stream *s)
{
    int i, n = 0;
    pthread_mutex_lock(&g_streams_lock);
    for (i = 0; i < IOS_MAX_STREAMS; i++) if (g_streams[i] == s) g_streams[i] = NULL;
    for (i = 0; i < IOS_MAX_STREAMS; i++) if (g_streams[i]) n++;
    pthread_mutex_unlock(&g_streams_lock);
    fprintf(stderr, "[ios-astream] ml739 RELEASE stream=%p (%d still live)\n", (void *)s, n);
}

/* ml738: this driver is a documented singleton -- see the comment on
 * struct ios_stream. One title opens TWO concurrent render streams with
 * different formats (48k/2ch PCM16, then 48k/2ch float32), which is exactly
 * the case the comment says needs a table. Every client is handed the SAME
 * handle (&g_stream), so the driver cannot tell them apart: creating the
 * second tears down the first's AudioUnit, set_event_handle overwrites the
 * first client's event, releasing either invalidates both, and they share one
 * ring, one padding counter and one playback position.
 *
 * Instrument before changing behaviour: generation, the handle handed out, the
 * event handle and the calling thread, so the interleaving is visible rather
 * than inferred. */
static unsigned long long ios_current_tid(void)
{
    uint64_t t = 0;
    pthread_threadid_np(NULL, &t);
    return (unsigned long long)t;
}

static unsigned int g_stream_gen;
static unsigned int g_live_streams;
static mach_timebase_info_data_t g_timebase;

/* NtSetEvent lives in the same statically-linked unix ntdll. timer_loop
 * runs on a real Wine thread (mmdevapi spawns it into this unix call),
 * so calling into ntdll here is legal — unlike from the RT callback. */
extern NTSTATUS NtSetEvent( HANDLE handle, void *prev_state );

/* Per-function call counters. Print every 1000 calls so we can confirm
 * FMOD is actually exercising the driver. Cheap atomic increments. */
#include <stdatomic.h>
#define NULL_AUDIO_FN_COUNT 37
static _Atomic uint32_t g_call_counter[NULL_AUDIO_FN_COUNT];
#define LOG_FN_CALL(idx, name) do { \
    uint32_t n = atomic_fetch_add_explicit(&g_call_counter[idx], 1, memory_order_relaxed) + 1; \
    if (n == 1 || (n % 1000) == 0) { \
        char buf[128]; \
        int len = snprintf(buf, sizeof(buf), "[ios_audio] " name " #%u\n", n); \
        if (len > 0) write(STDERR_FILENO, buf, len); \
    } \
} while (0)

static uint64_t mach_to_ns(uint64_t mach) {
    if (!g_timebase.denom) mach_timebase_info(&g_timebase);
    return mach * g_timebase.numer / g_timebase.denom;
}

static uint64_t elapsed_ns_since(uint64_t mach_start) {
    return mach_to_ns(mach_absolute_time() - mach_start);
}

static uint64_t elapsed_frames(const struct ios_stream *s) {
    if (!s->started) return s->accumulated_frames;
    uint64_t ns = elapsed_ns_since(s->start_mach);
    /* frames = ns * rate / 1e9 */
    return s->accumulated_frames + (ns * s->sample_rate / 1000000000ull);
}

/* ------------------- Tier-2: RemoteIO real output ------------------- */

/* Core Audio real-time thread. Ring + atomics ONLY — no Wine calls, no
 * locks, no allocation, no logging. Underrun = silence (WASAPI-correct:
 * padding drains to 0 and the position clock pauses at write_pos). */
static OSStatus ios_audio_render_cb(void *refcon, AudioUnitRenderActionFlags *flags,
                                    const AudioTimeStamp *ts, UInt32 bus,
                                    UInt32 nframes, AudioBufferList *iodata) {
    struct ios_stream *s = refcon;
    BYTE *out = (BYTE *)iodata->mBuffers[0].mData;
    UINT32 fb = s->frame_bytes;
    UINT32 cap = s->buffer_frames;
    uint64_t play = atomic_load_explicit(&s->play_pos, memory_order_relaxed);
    uint64_t wr = atomic_load_explicit(&s->write_pos, memory_order_acquire);
    uint64_t avail = wr - play;
    UInt32 tocopy = avail < nframes ? (UInt32)avail : nframes;
    UInt32 i = 0;
    (void)flags; (void)ts; (void)bus;
    while (i < tocopy) {
        UINT32 idx = (UINT32)((play + i) % cap);
        UINT32 chunk = cap - idx;
        if (chunk > tocopy - i) chunk = tocopy - i;
        memcpy(out + (size_t)i * fb, s->ring + (size_t)idx * fb, (size_t)chunk * fb);
        i += chunk;
    }
    if (tocopy < nframes)
        memset(out + (size_t)tocopy * fb, 0, (size_t)(nframes - tocopy) * fb);
    atomic_store_explicit(&s->play_pos, play + tocopy, memory_order_release);
    return noErr;
}

/* Parse the WASAPI format into "is float?" — tag 3 = IEEE float, tag
 * 0xFFFE = extensible (SubFormat GUID first byte: 1 PCM, 3 float). */
static int ios_fmt_is_float(const struct WAVEFORMATEX_stub *fmt) {
    if (!fmt) return 0;
    if (fmt->wFormatTag == 3) return 1;
    if (fmt->wFormatTag == 0xFFFE && fmt->cbSize >= 22) {
        const uint8_t *sub = (const uint8_t *)fmt + 24;
        return sub[0] == 3;
    }
    return 0;
}

/* Build the RemoteIO unit for the negotiated stream format. Returns 0 on
 * success; any failure leaves s->au NULL (null-mode fallback). */
static int ios_audio_setup_unit(struct ios_stream *s, const struct WAVEFORMATEX_stub *fmt) {
    AudioComponentDescription desc = {0};
    AudioComponent comp;
    AudioStreamBasicDescription asbd = {0};
    AURenderCallbackStruct cb;
    OSStatus err;

    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    comp = AudioComponentFindNext(NULL, &desc);
    if (!comp) { fprintf(stderr, "[ios_audio] RemoteIO component not found\n"); return -1; }
    if ((err = AudioComponentInstanceNew(comp, &s->au))) {
        fprintf(stderr, "[ios_audio] AudioComponentInstanceNew: %d\n", (int)err);
        s->au = NULL; return -1;
    }

    asbd.mSampleRate = s->sample_rate;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsPacked |
        (ios_fmt_is_float(fmt) ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger);
    asbd.mBytesPerPacket = s->frame_bytes;
    asbd.mFramesPerPacket = 1;
    asbd.mBytesPerFrame = s->frame_bytes;
    asbd.mChannelsPerFrame = s->channels;
    asbd.mBitsPerChannel = (s->frame_bytes / s->channels) * 8;

    err = AudioUnitSetProperty(s->au, kAudioUnitProperty_StreamFormat,
                               kAudioUnitScope_Input, 0, &asbd, sizeof(asbd));
    if (err) {
        fprintf(stderr, "[ios_audio] SetProperty(StreamFormat rate=%u ch=%u fb=%u float=%d): %d\n",
                s->sample_rate, s->channels, s->frame_bytes, ios_fmt_is_float(fmt), (int)err);
        goto fail;
    }

    cb.inputProc = ios_audio_render_cb;
    cb.inputProcRefCon = s;
    err = AudioUnitSetProperty(s->au, kAudioUnitProperty_SetRenderCallback,
                               kAudioUnitScope_Input, 0, &cb, sizeof(cb));
    if (err) { fprintf(stderr, "[ios_audio] SetRenderCallback: %d\n", (int)err); goto fail; }

    if ((err = AudioUnitInitialize(s->au))) {
        fprintf(stderr, "[ios_audio] AudioUnitInitialize: %d\n", (int)err);
        goto fail;
    }
    fprintf(stderr, "[ios_audio] RemoteIO ready: %u Hz, %u ch, %u B/frame, float=%d, ring=%u frames\n",
            s->sample_rate, s->channels, s->frame_bytes, ios_fmt_is_float(fmt), s->buffer_frames);
    return 0;
fail:
    AudioComponentInstanceDispose(s->au);
    s->au = NULL;
    return -1;
}

static void ios_audio_teardown_unit(struct ios_stream *s) {
    if (!s->au) return;
    if (s->au_running) AudioOutputUnitStop(s->au);
    AudioUnitUninitialize(s->au);
    AudioComponentInstanceDispose(s->au);
    s->au = NULL;
    s->au_running = 0;
}

/* ---------------------------------------------------------------- */

static NTSTATUS ios_process_attach(void *args) {
    LOG_FN_CALL(0, "process_attach");
    (void)args;
    pthread_mutex_init(&g_streams_lock, NULL);
    if (!g_timebase.denom) mach_timebase_info(&g_timebase);
    return STATUS_SUCCESS;
}

static NTSTATUS ios_process_detach(void *args) {
    (void)args;
    /* ml739: tear down whatever is still registered. Previously this freed the
     * singleton's scratch buffer only; with a stream per client anything still
     * live at process detach has to be disposed individually. */
    {
        int i;
        for (i = 0; i < IOS_MAX_STREAMS; i++) {
            struct ios_stream *s;
            pthread_mutex_lock(&g_streams_lock);
            s = g_streams[i];
            g_streams[i] = NULL;
            pthread_mutex_unlock(&g_streams_lock);
            if (!s) continue;
            /* Stop the hardware, but do NOT free. release_stream joins a
             * stream's own timer thread before freeing it; here we have no
             * handle to join, and freeing while that thread may still be
             * looping is a use-after-free. The process is going away, so
             * leaving the memory is the safe trade. */
            s->valid = 0;
            s->started = 0;
            ios_audio_teardown_unit(s);
        }
    }
    return STATUS_SUCCESS;
}

static NTSTATUS ios_main_loop(void *args) {
    /* CONTRACT (mmdevapi client.c main_loop_start): the PE side blocks
     * WaitForSingleObject(event, INFINITE) until the driver signals this
     * event. Returning WITHOUT signaling deadlocks whoever triggered
     * driver init — FMOD's IAudioClient path — which held Thumper on the
     * splash screen (2026-07-05; and likely the misread May "FMOD probes
     * then stops" observation). winecoreaudio does exactly this. */
    struct main_loop_params { HANDLE event; } *p = args;
    LOG_FN_CALL(2, "main_loop");
    NtSetEvent(p->event, NULL);
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_endpoint_ids(void *args) {
    LOG_FN_CALL(3, "get_endpoint_ids");
    struct get_endpoint_ids_params *p = args;
    /* Only render endpoints; refuse capture entirely. */
    if (p->flow != eRender) {
        p->num = 0;
        p->default_idx = 0;
        p->result = S_OK;
        return STATUS_SUCCESS;
    }
    /* mmdevapi treats endpoint.name as WCHAR* (wide string, 2 bytes/char)
     * and endpoint.device as char* (single-byte). Both stored as byte
     * offsets from the endpoints buffer base. */
    static const WCHAR dev_name_w[] = { 'i','O','S',' ','N','u','l','l', 0 };
    unsigned int name_bytes = sizeof(dev_name_w);
    unsigned int device_bytes = sizeof(IOS_DEVICE_NAME);
    unsigned int needed = sizeof(struct endpoint) + name_bytes + device_bytes;
    if (p->size < needed) {
        p->num = 1;
        p->default_idx = 0;
        p->result = 0x80070057L; /* E_INVALIDARG style — signal "need more space" */
        return STATUS_SUCCESS;
    }
    /* Layout: [endpoint][wide_name\0\0][device_str\0] */
    unsigned int name_off = sizeof(struct endpoint);
    unsigned int device_off = name_off + name_bytes;
    char *buf = (char *)p->endpoints;
    memcpy(buf + name_off, dev_name_w, name_bytes);
    memcpy(buf + device_off, IOS_DEVICE_NAME, device_bytes);
    p->endpoints[0].name = name_off;
    p->endpoints[0].device = device_off;
    p->num = 1;
    p->default_idx = 0;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_create_stream(void *args) {
    LOG_FN_CALL(4, "create_stream");
    struct create_stream_params *p = args;
    uint64_t dur_frames;
    /* ml739: a stream per client. */
    struct ios_stream *s = calloc(1, sizeof(*s));
    if (!s) { p->result = E_OUTOFMEMORY; return STATUS_SUCCESS; }
    s->valid = 1;
    s->started = 0;
    s->start_mach = 0;
    s->accumulated_frames = 0;
    s->sample_rate = p->fmt && p->fmt->nSamplesPerSec ? p->fmt->nSamplesPerSec : IOS_AUDIO_SAMPLE_RATE;
    s->channels = p->fmt && p->fmt->nChannels ? p->fmt->nChannels : IOS_AUDIO_CHANNELS;
    s->frame_bytes = p->fmt && p->fmt->nBlockAlign ? p->fmt->nBlockAlign
                          : (s->channels * IOS_AUDIO_BITS) / 8;
    /* Ring capacity: the requested buffer duration (100ns units), floor
     * 100ms so a slow FEX-translated mixer has slack. */
    dur_frames = (uint64_t)(p->duration > 0 ? p->duration : 0) * s->sample_rate / 10000000ull;
    if (dur_frames < s->sample_rate / 10) dur_frames = s->sample_rate / 10;
    if (dur_frames > s->sample_rate * 4) dur_frames = s->sample_rate * 4;
    s->buffer_frames = (UINT32)dur_frames;
    free(s->ring);
    s->ring = (BYTE *)calloc(s->buffer_frames, s->frame_bytes);
    free(s->render_scratch);
    s->scratch_frames = s->buffer_frames;
    s->render_scratch = (BYTE *)calloc(s->scratch_frames, s->frame_bytes);
    s->pending_frames = 0;
    atomic_store(&s->write_pos, 0);
    atomic_store(&s->play_pos, 0);

    if (p->flow == eRender && s->ring)
        ios_audio_setup_unit(s, p->fmt);   /* failure -> null-mode */

    if (p->channel_count) *p->channel_count = s->channels;
    if (p->stream) *p->stream = (stream_handle)(uintptr_t)s;
    fprintf(stderr, "[ios-astream] ml738 CREATED gen=%u handle=%p rate=%u ch=%u fb=%u\n",
            g_stream_gen, (void *)s, s->sample_rate, s->channels,
            s->frame_bytes);
    if (stream_register(s)) {
        fprintf(stderr, "[ios-astream] ml739 too many streams -- refusing\n");
        ios_audio_teardown_unit(s);
        free(s->render_scratch); free(s->ring); free(s);
        /* the handle was published above; it now points at freed memory */
        if (p->stream) *p->stream = 0;
        p->result = E_OUTOFMEMORY;
        return STATUS_SUCCESS;
    }
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_release_stream(void *args) {
    struct release_stream_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);

    if (!s) { p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }

    /* Order matters. Mark this stream dead first so its own timer thread
     * leaves its loop, join that thread, and only then dispose the AudioUnit
     * so the render callback cannot still be running against memory we are
     * about to free. Nothing here touches another client's stream. */
    s->valid = 0;
    s->started = 0;
    if (p->timer_thread) {
        NtWaitForSingleObject(p->timer_thread, FALSE, NULL);
        NtClose(p->timer_thread);
    }
    ios_audio_teardown_unit(s);
    stream_unregister(s);
    free(s->render_scratch);
    free(s->ring);
    free(s);
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_start(void *args) {
    LOG_FN_CALL(6, "start");
    struct stream_handle_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    if (!s->started) {
        if (s->au && !s->au_running) {
            OSStatus err = AudioOutputUnitStart(s->au);
            if (err) {
                fprintf(stderr, "[ios_audio] AudioOutputUnitStart: %d — null-mode\n", (int)err);
                ios_audio_teardown_unit(s);
            } else {
                s->au_running = 1;
            }
        }
        s->start_mach = mach_absolute_time();
        s->started = 1;
    }
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_stop(void *args) {
    struct stream_handle_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    if (s->started) {
        if (s->au && s->au_running) {
            AudioOutputUnitStop(s->au);
            s->au_running = 0;
        }
        s->accumulated_frames = elapsed_frames(s);
        s->started = 0;
    }
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_reset(void *args) {
    struct stream_handle_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    s->started = 0;
    s->accumulated_frames = 0;
    s->start_mach = 0;
    /* Drop queued-but-unplayed audio (only legal while stopped). */
    atomic_store(&s->write_pos, 0);
    atomic_store(&s->play_pos, 0);
    s->pending_frames = 0;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_timer_loop(void *args) {
    /* Runs on a dedicated Wine thread mmdevapi spawns for event-driven
     * clients. Wake the client every device period so it refills the
     * ring; exit when the stream dies. */
    struct timer_loop_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) return STATUS_SUCCESS;
    LOG_FN_CALL(9, "timer_loop");
    while (s->valid) {
        usleep(10000); /* device period, 10 ms */
        if (s->event && s->started)
            NtSetEvent(s->event, NULL);
    }
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_render_buffer(void *args) {
    LOG_FN_CALL(10, "get_render_buffer");
    struct get_render_buffer_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { if (p->data) *p->data = NULL; p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    if (s->au) {
        uint64_t padding = atomic_load(&s->write_pos) - atomic_load(&s->play_pos);
        if (p->frames + padding > s->buffer_frames) {
            p->result = (HRESULT)0x88890006L; /* AUDCLNT_E_BUFFER_TOO_LARGE */
            if (p->data) *p->data = NULL;
            return STATUS_SUCCESS;
        }
    }
    if (p->frames > s->scratch_frames) {
        /* Client asked for more than the ring — grow scratch; the copy in
         * release clamps to ring capacity anyway. */
        BYTE *ns = (BYTE *)realloc(s->render_scratch,
                                   (size_t)p->frames * s->frame_bytes);
        if (!ns) { p->result = E_FAIL; return STATUS_SUCCESS; }
        s->render_scratch = ns;
        s->scratch_frames = p->frames;
    }
    s->pending_frames = p->frames;
    if (p->data) *p->data = s->render_scratch;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_release_render_buffer(void *args) {
    struct release_render_buffer_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    if (s->au && p->written_frames > 0) {
        UINT32 fb = s->frame_bytes;
        UINT32 cap = s->buffer_frames;
        UINT32 n = p->written_frames;
        uint64_t wr = atomic_load_explicit(&s->write_pos, memory_order_relaxed);
        UINT32 i = 0;
        if (n > s->pending_frames) n = s->pending_frames;
        if (p->flags & 0x2 /* AUDCLNT_BUFFERFLAGS_SILENT */)
            memset(s->render_scratch, 0, (size_t)n * fb);
        while (i < n) {
            UINT32 idx = (UINT32)((wr + i) % cap);
            UINT32 chunk = cap - idx;
            if (chunk > n - i) chunk = n - i;
            memcpy(s->ring + (size_t)idx * fb,
                   s->render_scratch + (size_t)i * fb, (size_t)chunk * fb);
            i += chunk;
        }
        /* release-store AFTER the copy so the RT callback never reads
         * frames that aren't fully written */
        atomic_store_explicit(&s->write_pos, wr + n, memory_order_release);
    }
    s->pending_frames = 0;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_capture_buffer(void *args) {
    struct get_capture_buffer_params *p = args;
    if (p->frames) *p->frames = 0;
    if (p->data) *p->data = NULL;
    if (p->flags) *p->flags = 0;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_release_capture_buffer(void *args) {
    struct release_capture_buffer_params *p = args;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_is_format_supported(void *args) {
    struct is_format_supported_params *p = args;
    LOG_FN_CALL(14, "is_format_supported");
    /* Accept anything. */
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_loopback_capture_device(void *args) {
    (void)args;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_mix_format(void *args) {
    struct get_mix_format_params *p = args;
    LOG_FN_CALL(16, "get_mix_format");
    /* WAVEFORMATEXTENSIBLE is 40 bytes; first 18 are WAVEFORMATEX */
    if (p->fmt) {
        memset(p->fmt, 0, 40);
        struct WAVEFORMATEX_stub *f = p->fmt;
        f->wFormatTag = 0xFFFE; /* WAVE_FORMAT_EXTENSIBLE */
        f->nChannels = IOS_AUDIO_CHANNELS;
        f->nSamplesPerSec = IOS_AUDIO_SAMPLE_RATE;
        f->wBitsPerSample = IOS_AUDIO_BITS;
        f->nBlockAlign = IOS_AUDIO_FRAME_BYTES;
        f->nAvgBytesPerSec = IOS_AUDIO_SAMPLE_RATE * IOS_AUDIO_FRAME_BYTES;
        f->cbSize = 22; /* extensible body */
        /* Extensible body: Samples (2), ChannelMask (4), SubFormat (16).
         * KSDATAFORMAT_SUBTYPE_PCM = {00000001-0000-0010-8000-00AA00389B71} */
        uint16_t *samples = (uint16_t *)((char *)p->fmt + 18);
        *samples = IOS_AUDIO_BITS;
        uint32_t *mask = (uint32_t *)((char *)p->fmt + 20);
        *mask = 0x3; /* SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT */
        /* SubFormat GUID PCM */
        static const uint8_t pcm_guid[16] = {
            0x01,0x00,0x00,0x00, 0x00,0x00, 0x10,0x00,
            0x80,0x00, 0x00,0xAA, 0x00,0x38,0x9B,0x71
        };
        memcpy((char *)p->fmt + 24, pcm_guid, 16);
    }
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_device_period(void *args) {
    struct get_device_period_params *p = args;
    if (p->def_period) *p->def_period = 100000; /* 10 ms in 100ns units */
    if (p->min_period) *p->min_period = 50000;  /* 5 ms */
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_buffer_size(void *args) {
    struct get_buffer_size_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { if (p->frames) *p->frames = 0; p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    if (p->frames) *p->frames = s->buffer_frames ? s->buffer_frames
                                                       : IOS_AUDIO_BUFFER_FRAMES;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_latency(void *args) {
    struct get_latency_params *p = args;
    if (p->latency) *p->latency = 100000; /* 10 ms */
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_current_padding(void *args) {
    LOG_FN_CALL(20, "get_current_padding");
    struct get_current_padding_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { if (p->padding) *p->padding = 0; p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    if (p->padding) {
        if (s->au) {
            uint64_t pad = atomic_load(&s->write_pos) - atomic_load(&s->play_pos);
            *p->padding = (UINT32)(pad > s->buffer_frames ? s->buffer_frames : pad);
        } else {
            *p->padding = 0; /* null-mode: always hungry */
        }
    }
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_next_packet_size(void *args) {
    struct get_next_packet_size_params *p = args;
    if (p->frames) *p->frames = 0;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_frequency(void *args) {
    struct get_frequency_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { if (p->freq) *p->freq = 0; p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    /* Returns the device frequency in Hz — what units IAudioClock uses. */
    if (p->freq) *p->freq = s->sample_rate ? s->sample_rate : IOS_AUDIO_SAMPLE_RATE;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_position(void *args) {
    LOG_FN_CALL(23, "get_position");
    struct get_position_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { if (p->pos) *p->pos = 0; p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    /* THIS is the function that drives FMOD's clock. Tier-2: frames the
     * RT callback actually consumed — the true hardware clock. Null-mode
     * fallback: wall-clock synthesis as before. */
    if (p->pos) {
        if (s->au)
            *p->pos = atomic_load(&s->play_pos);
        else
            *p->pos = elapsed_frames(s);
    }
    if (p->qpctime) *p->qpctime = mach_to_ns(mach_absolute_time()) / 100; /* 100ns ticks */
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_set_volumes(void *args) {
    (void)args;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_set_event_handle(void *args) {
    struct set_event_handle_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    if (s->event && s->event != p->event)
        fprintf(stderr, "[ios-astream] ml738 EVENT OVERWRITE gen=%u old=%p new=%p tid=%llx "
                        "-- the previous client will never be signalled again\n",
                g_stream_gen, s->event, p->event,
                (unsigned long long)ios_current_tid());
    else
        fprintf(stderr, "[ios-astream] ml738 EVENT set gen=%u handle=%p tid=%llx\n",
                g_stream_gen, p->event, (unsigned long long)ios_current_tid());
    s->event = p->event;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_set_sample_rate(void *args) {
    struct set_sample_rate_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    if (p->rate > 0) s->sample_rate = (UINT32)p->rate;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_test_connect(void *args) {
    LOG_FN_CALL(27, "test_connect");
    struct test_connect_params *p = args;
    p->priority = Priority_Preferred;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_is_started(void *args) {
    struct is_started_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    p->result = s->started ? S_OK : S_FALSE;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_prop_value(void *args) {
    struct get_prop_value_params *p = args;
    p->result = E_FAIL; /* property not supported — mmdevapi falls back */
    return STATUS_SUCCESS;
}

static NTSTATUS ios_midi_stub(void *args) {
    (void)args;
    return STATUS_SUCCESS;
}

/* Table indexed by enum unix_funcs in mmdevapi's unixlib.h (37 entries).
 * Order MUST match the enum exactly. */
const void *audio_null_ios_unix_call_funcs[] = {
    ios_process_attach,                /* process_attach */
    ios_process_detach,                /* process_detach */
    ios_main_loop,                     /* main_loop */
    ios_get_endpoint_ids,              /* get_endpoint_ids */
    ios_create_stream,                 /* create_stream */
    ios_release_stream,                /* release_stream */
    ios_start,                         /* start */
    ios_stop,                          /* stop */
    ios_reset,                         /* reset */
    ios_timer_loop,                    /* timer_loop */
    ios_get_render_buffer,             /* get_render_buffer */
    ios_release_render_buffer,         /* release_render_buffer */
    ios_get_capture_buffer,            /* get_capture_buffer */
    ios_release_capture_buffer,        /* release_capture_buffer */
    ios_is_format_supported,           /* is_format_supported */
    ios_get_loopback_capture_device,   /* get_loopback_capture_device */
    ios_get_mix_format,                /* get_mix_format */
    ios_get_device_period,             /* get_device_period */
    ios_get_buffer_size,               /* get_buffer_size */
    ios_get_latency,                   /* get_latency */
    ios_get_current_padding,           /* get_current_padding */
    ios_get_next_packet_size,          /* get_next_packet_size */
    ios_get_frequency,                 /* get_frequency */
    ios_get_position,                  /* get_position */
    ios_set_volumes,                   /* set_volumes */
    ios_set_event_handle,              /* set_event_handle */
    ios_set_sample_rate,               /* set_sample_rate */
    ios_test_connect,                  /* test_connect */
    ios_is_started,                    /* is_started */
    ios_get_prop_value,                /* get_prop_value */
    ios_midi_stub,                     /* midi_get_driver */
    ios_midi_stub,                     /* midi_init */
    ios_midi_stub,                     /* midi_release */
    ios_midi_stub,                     /* midi_out_message */
    ios_midi_stub,                     /* midi_in_message */
    ios_midi_stub,                     /* midi_notify_wait */
    ios_midi_stub,                     /* aux_message */
};
