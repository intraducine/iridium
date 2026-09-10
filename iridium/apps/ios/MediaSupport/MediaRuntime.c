// Iridium iOS media adapter. Wine sources retain Madeira's GPL notices.
#include <gst/gst.h>
#include <pthread.h>
#include <stdio.h>

GST_PLUGIN_STATIC_DECLARE(coreelements);
GST_PLUGIN_STATIC_DECLARE(typefindfunctions);
GST_PLUGIN_STATIC_DECLARE(playback);
GST_PLUGIN_STATIC_DECLARE(isomp4);
GST_PLUGIN_STATIC_DECLARE(videoparsersbad);
GST_PLUGIN_STATIC_DECLARE(audioparsers);
GST_PLUGIN_STATIC_DECLARE(applemedia);
GST_PLUGIN_STATIC_DECLARE(videoconvertscale);
GST_PLUGIN_STATIC_DECLARE(audioconvert);
GST_PLUGIN_STATIC_DECLARE(audioresample);
GST_PLUGIN_STATIC_DECLARE(osxaudio);
GST_PLUGIN_STATIC_DECLARE(deinterlace);
GST_PLUGIN_STATIC_DECLARE(videofilter);
GST_PLUGIN_STATIC_DECLARE(libav);
GST_PLUGIN_STATIC_DECLARE(matroska);
GST_PLUGIN_STATIC_DECLARE(ogg);
GST_PLUGIN_STATIC_DECLARE(theora);
GST_PLUGIN_STATIC_DECLARE(vorbis);
GST_PLUGIN_STATIC_DECLARE(opus);
GST_PLUGIN_STATIC_DECLARE(avi);
GST_PLUGIN_STATIC_DECLARE(asf);
GST_PLUGIN_STATIC_DECLARE(mpegpsdemux);
GST_PLUGIN_STATIC_DECLARE(mpegtsdemux);
GST_PLUGIN_STATIC_DECLARE(mpg123);
extern const void *iridium_media_unix_funcs[];
static pthread_once_t once = PTHREAD_ONCE_INIT;
static void initialize(void) {
    gst_init(NULL, NULL);
    GST_PLUGIN_STATIC_REGISTER(coreelements);
    GST_PLUGIN_STATIC_REGISTER(typefindfunctions);
    GST_PLUGIN_STATIC_REGISTER(playback);
    GST_PLUGIN_STATIC_REGISTER(isomp4);
    GST_PLUGIN_STATIC_REGISTER(videoparsersbad);
    GST_PLUGIN_STATIC_REGISTER(audioparsers);
    GST_PLUGIN_STATIC_REGISTER(applemedia);
    GST_PLUGIN_STATIC_REGISTER(videoconvertscale);
    GST_PLUGIN_STATIC_REGISTER(audioconvert);
    GST_PLUGIN_STATIC_REGISTER(audioresample);
    GST_PLUGIN_STATIC_REGISTER(osxaudio);
    GST_PLUGIN_STATIC_REGISTER(deinterlace);
    GST_PLUGIN_STATIC_REGISTER(videofilter);
    GST_PLUGIN_STATIC_REGISTER(libav);
    GST_PLUGIN_STATIC_REGISTER(matroska);
    GST_PLUGIN_STATIC_REGISTER(ogg);
    GST_PLUGIN_STATIC_REGISTER(theora);
    GST_PLUGIN_STATIC_REGISTER(vorbis);
    GST_PLUGIN_STATIC_REGISTER(opus);
    GST_PLUGIN_STATIC_REGISTER(avi);
    GST_PLUGIN_STATIC_REGISTER(asf);
    GST_PLUGIN_STATIC_REGISTER(mpegpsdemux);
    GST_PLUGIN_STATIC_REGISTER(mpegtsdemux);
    GST_PLUGIN_STATIC_REGISTER(mpg123);
    fprintf(stderr, "[IridiumMedia] GStreamer iOS static plugins registered\n");
    const char *required[] = {"decodebin", "qtdemux", "deinterlace", "videoconvert",
        "audioconvert", "audioresample", "avdec_h264", "avdec_aac", "asfdemux",
        "avdec_wmv3", "avdec_vc1", "avdec_wmav2", "matroskademux", "avdec_vp8",
        "avdec_vp9", "vorbisdec", "opusdec", "oggdemux", "theoradec", "avidemux",
        "avdec_mpeg4", "avdec_mjpeg", "mpg123audiodec", "mpegpsdemux", "avdec_mpeg2video"};
    for (unsigned i = 0; i < sizeof(required) / sizeof(required[0]); ++i) {
        GstElementFactory *factory = gst_element_factory_find(required[i]);
        fprintf(stderr, "[IridiumMedia] factory %s: %s\n", required[i], factory ? "available" : "MISSING");
        if (factory) gst_object_unref(factory);
    }
}
__attribute__((visibility("default"))) const void *iridium_media_get_unix_funcs(void) {
    pthread_once(&once, initialize);
    return iridium_media_unix_funcs;
}
