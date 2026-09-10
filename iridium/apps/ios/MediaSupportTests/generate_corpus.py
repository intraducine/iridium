"""Create synthetic four-second AV clips; no game assets are included."""
import pathlib, subprocess, sys
out = pathlib.Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
cases = [
 ('h264-aac.mp4','libx264','aac',[]),
 ('wmv2-wma2.asf','wmv2','wmav2',[]),
 ('vp8-vorbis.webm','libvpx','vorbis',['-strict','experimental']),
 ('vp9-opus.webm','libvpx-vp9','libopus',[]),
 ('mpeg4-mp3.avi','mpeg4','libmp3lame',[]),
 ('mjpeg-pcm.avi','mjpeg','pcm_s16le',[]),
 ('mpeg1-mp2.mpg','mpeg1video','mp2',[]),
 ('mpeg2-mp2.mpg','mpeg2video','mp2',[]),
]
for name,video,audio,extra in cases:
 subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y',
  '-f','lavfi','-i','testsrc2=size=320x180:rate=30',
  '-f','lavfi','-i','sine=frequency=1000:sample_rate=48000',
  '-t','4','-ac','2','-c:v',video,'-c:a',audio,*extra,str(out/name)],check=True)
 print(name)
