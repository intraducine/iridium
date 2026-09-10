/* Diagnostic for converted, asynchronous audio/video sample delivery. */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mfapi.h>
#include <d3d11.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <stdio.h>

static HANDLE ready;
static FILE *logfile;
static HRESULT status;
static DWORD actual, sample_flags;
static LONGLONG sample_time;
static IMFSample *received;
static HRESULT WINAPI query(IMFSourceReaderCallback *self, REFIID iid, void **out) {
    *out = NULL;
    if (!IsEqualIID(iid, &IID_IUnknown) && !IsEqualIID(iid, &IID_IMFSourceReaderCallback)) return E_NOINTERFACE;
    *out = self; return S_OK;
}
static ULONG WINAPI ref(IMFSourceReaderCallback *self) { return 2; }
static HRESULT WINAPI sample(IMFSourceReaderCallback *self, HRESULT hr, DWORD stream, DWORD flags, LONGLONG time, IMFSample *value) {
    status = hr; actual = stream; sample_flags = flags; sample_time = time;
    received = value;
    if (value) IMFSample_AddRef(value);
    SetEvent(ready); return S_OK;
}
static HRESULT WINAPI flush(IMFSourceReaderCallback *self, DWORD stream) { return S_OK; }
static HRESULT WINAPI event(IMFSourceReaderCallback *self, DWORD stream, IMFMediaEvent *value) { return S_OK; }
static IMFSourceReaderCallbackVtbl callbacks = {query, ref, ref, sample, flush, event};
static IMFSourceReaderCallback callback = {&callbacks};

static HRESULT format(IMFSourceReader *reader, DWORD stream, const GUID *major, const GUID *subtype) {
    IMFMediaType *type = NULL;
    HRESULT hr = MFCreateMediaType(&type);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetGUID(type, &MF_MT_MAJOR_TYPE, major);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetGUID(type, &MF_MT_SUBTYPE, subtype);
    if (SUCCEEDED(hr)) hr = IMFSourceReader_SetCurrentMediaType(reader, stream, NULL, type);
    if (type) IMFMediaType_Release(type);
    return hr;
}

static HRESULT readback_pixels(ID3D11Device *device, ID3D11Texture2D *texture, unsigned frame) {
    D3D11_TEXTURE2D_DESC desc;
    ID3D11Texture2D_GetDesc(texture, &desc);
    fprintf(logfile, "readback frame=%u format=%u size=%ux%u misc=%x\n", frame, desc.Format, desc.Width, desc.Height, desc.MiscFlags);
    if (desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM && desc.Format != DXGI_FORMAT_B8G8R8X8_UNORM) return E_UNEXPECTED;
    desc.Usage = D3D11_USAGE_STAGING; desc.BindFlags = 0; desc.MiscFlags = 0; desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ID3D11Texture2D *staging = NULL;
    ID3D11DeviceContext *context = NULL;
    HRESULT hr = ID3D11Device_CreateTexture2D(device, &desc, NULL, &staging);
    if (FAILED(hr)) return hr;
    ID3D11Device_GetImmediateContext(device, &context);
    ID3D11DeviceContext_CopyResource(context, (ID3D11Resource *)staging, (ID3D11Resource *)texture);
    D3D11_MAPPED_SUBRESOURCE mapped;
    hr = ID3D11DeviceContext_Map(context, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &mapped);
    if (SUCCEEDED(hr)) {
        char path[100]; snprintf(path, sizeof(path), "C:\\iridium-video-frame-%u.ppm", frame);
        FILE *image = fopen(path, "wb");
        unsigned bright = 0, opaque = 0, maximum = 0;
        if (image) fprintf(image, "P6\n%u %u\n255\n", desc.Width, desc.Height);
        for (UINT y=0; y<desc.Height; y++) {
            BYTE *row = (BYTE *)mapped.pData + y*mapped.RowPitch;
            for (UINT x=0; x<desc.Width; x++) {
                BYTE rgb[3] = {row[x*4+2],row[x*4+1],row[x*4]};
                unsigned value = rgb[0]+rgb[1]+rgb[2];
                if (value > 30) bright++;
                if (row[x*4+3] == 255) opaque++;
                if (value > maximum) maximum=value;
                if (image && fwrite(rgb,1,3,image) != 3) { fclose(image); image=NULL; hr=E_FAIL; }
            }
        }
        if (image) fclose(image); else hr=E_FAIL;
        fprintf(logfile, "pixels frame=%u bright=%u opaque=%u maxRGBSum=%u\n", frame, bright, opaque, maximum);
        ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)staging, 0);
    }
    fprintf(logfile, "readback=%08lx\n", hr);
    ID3D11DeviceContext_Release(context); ID3D11Texture2D_Release(staging);
    return hr;
}

static HRESULT inspect_pixels(ID3D11Device *device, ID3D11Texture2D *texture, unsigned frame) {
    HRESULT hr = readback_pixels(device, texture, frame);
    if (FAILED(hr)) return hr;
    IDXGIResource *resource = NULL;
    HANDLE handle = NULL;
    ID3D11Device *other = NULL;
    ID3D11Texture2D *opened = NULL;
    hr = ID3D11Texture2D_QueryInterface(texture, &IID_IDXGIResource, (void **)&resource);
    if (SUCCEEDED(hr)) hr = IDXGIResource_GetSharedHandle(resource, &handle);
    fprintf(logfile, "GetSharedHandle=%08lx handle=%p\n", hr, handle);
    if (SUCCEEDED(hr)) hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, D3D11_CREATE_DEVICE_BGRA_SUPPORT, NULL, 0, D3D11_SDK_VERSION, &other, NULL, NULL);
    if (SUCCEEDED(hr)) hr = ID3D11Device_OpenSharedResource(other, handle, &IID_ID3D11Texture2D, (void **)&opened);
    fprintf(logfile, "OpenSharedResource=%08lx\n", hr);
    if (SUCCEEDED(hr)) hr = readback_pixels(other, opened, frame+10000);
    if (opened) ID3D11Texture2D_Release(opened);
    if (other) ID3D11Device_Release(other);
    if (resource) IDXGIResource_Release(resource);
    return hr;
}

int main(void) {
    IMFSourceReader *reader = NULL;
    IMFAttributes *attrs = NULL;
    ID3D11Device *device = NULL;
    IMFDXGIDeviceManager *manager = NULL;
    UINT reset_token;
    unsigned textures = 0;
    unsigned counts[16] = {0}, ended = 0;
    LONGLONG last[16] = {0};
    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    logfile = fopen("C:\\iridium-media-check.log", "w");
    if (!logfile) return 1;
    setvbuf(logfile, NULL, _IONBF, 0);
    fprintf(logfile, "ASYNC GPU ARGB32 + PCM test COM=%08lx\n", hr);
    ready = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (!ready) return 2;
    hr = MFStartup(MF_VERSION, MFSTARTUP_FULL);
    if (FAILED(hr)) goto done;
    hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, D3D11_CREATE_DEVICE_BGRA_SUPPORT, NULL, 0, D3D11_SDK_VERSION, &device, NULL, NULL);
    fprintf(logfile, "D3D11CreateDevice=%08lx\n", hr);
    if (FAILED(hr)) goto done;
    hr = MFCreateDXGIDeviceManager(&reset_token, &manager);
    if (SUCCEEDED(hr)) hr = IMFDXGIDeviceManager_ResetDevice(manager, (IUnknown *)device, reset_token);
    if (FAILED(hr)) goto done;
    hr = MFCreateAttributes(&attrs, 3);
    if (FAILED(hr)) goto done;
    hr = IMFAttributes_SetUINT32(attrs, &MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, TRUE);
    if (SUCCEEDED(hr)) hr = IMFAttributes_SetUINT32(attrs, &MF_SOURCE_READER_D3D11_BIND_FLAGS, D3D11_BIND_SHADER_RESOURCE);
    if (SUCCEEDED(hr)) hr = IMFAttributes_SetUINT32(attrs, &MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
    if (SUCCEEDED(hr)) hr = IMFAttributes_SetUnknown(attrs, &MF_SOURCE_READER_D3D_MANAGER, (IUnknown *)manager);
    if (SUCCEEDED(hr)) hr = IMFAttributes_SetUnknown(attrs, &MF_SOURCE_READER_ASYNC_CALLBACK, (IUnknown *)&callback);
    if (SUCCEEDED(hr)) hr = MFCreateSourceReaderFromURL(L"C:\\iridium-intro-test.mp4", attrs, &reader);
    fprintf(logfile, "CreateSourceReader=%08lx\n", hr);
    if (FAILED(hr)) goto done;
    hr = IMFSourceReader_SetStreamSelection(reader, MF_SOURCE_READER_ALL_STREAMS, FALSE);
    if (SUCCEEDED(hr)) hr = IMFSourceReader_SetStreamSelection(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, TRUE);
    if (SUCCEEDED(hr)) hr = IMFSourceReader_SetStreamSelection(reader, MF_SOURCE_READER_FIRST_AUDIO_STREAM, TRUE);
    if (SUCCEEDED(hr)) hr = format(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, &MFMediaType_Video, &MFVideoFormat_ARGB32);
    fprintf(logfile, "GPU ARGB32=%08lx\n", hr);
    if (SUCCEEDED(hr)) hr = format(reader, MF_SOURCE_READER_FIRST_AUDIO_STREAM, &MFMediaType_Audio, &MFAudioFormat_PCM);
    fprintf(logfile, "PCM=%08lx\n", hr);
    if (FAILED(hr)) goto done;
    for (unsigned n = 0; n < 30000 && ended < 2; n++) {
        received = NULL;
        hr = IMFSourceReader_ReadSample(reader, MF_SOURCE_READER_ANY_STREAM, 0, NULL, NULL, NULL, NULL);
        if (FAILED(hr)) { fprintf(logfile, "ReadSample request=%08lx\n", hr); break; }
        DWORD wait = WaitForSingleObject(ready, 30000);
        if (wait != WAIT_OBJECT_0) {
            fprintf(logfile, "CALLBACK TIMEOUT request=%u wait=%lu\n", n, wait);
            hr = HRESULT_FROM_WIN32(ERROR_TIMEOUT); break;
        }
        hr = status;
        if (FAILED(hr)) { fprintf(logfile, "callback error=%08lx stream=%lu\n", hr, actual); break; }
        if (actual >= 16) { hr = E_UNEXPECTED; break; }
        if (received) {
            DWORD bytes = 0;
            IMFSample_GetTotalLength(received, &bytes);
            if (actual == 0) {
                IMFMediaBuffer *buffer = NULL;
                IMFDXGIBuffer *dxgi = NULL;
                ID3D11Texture2D *texture = NULL;
                hr = IMFSample_GetBufferByIndex(received, 0, &buffer);
                if (SUCCEEDED(hr)) hr = IMFMediaBuffer_QueryInterface(buffer, &IID_IMFDXGIBuffer, (void **)&dxgi);
                if (SUCCEEDED(hr)) hr = IMFDXGIBuffer_GetResource(dxgi, &IID_ID3D11Texture2D, (void **)&texture);
                if (texture) {
                    textures++;
                    if (textures == 125 || textures == 400) hr = inspect_pixels(device, texture, textures);
                    ID3D11Texture2D_Release(texture);
                }
                if (dxgi) IMFDXGIBuffer_Release(dxgi);
                if (buffer) IMFMediaBuffer_Release(buffer);
                if (FAILED(hr)) { fprintf(logfile, "GPU buffer failed=%08lx\n", hr); IMFSample_Release(received); received = NULL; break; }
            }
            counts[actual]++; last[actual] = sample_time;
            if (counts[actual] <= 2 || counts[actual] % 100 == 0)
                fprintf(logfile, "stream=%lu count=%u bytes=%lu time=%lld\n", actual, counts[actual], bytes, sample_time);
            IMFSample_Release(received); received = NULL;
        }
        if (sample_flags & MF_SOURCE_READERF_ERROR) { hr = E_FAIL; break; }
        if (sample_flags & MF_SOURCE_READERF_ENDOFSTREAM) {
            fprintf(logfile, "EOS stream=%lu count=%u\n", actual, counts[actual]);
            ended++;
            hr = IMFSourceReader_SetStreamSelection(reader, actual, FALSE);
            if (FAILED(hr)) break;
        }
    }
    if (SUCCEEDED(hr) && (ended != 2 || !textures)) hr = E_FAIL;
done:
    for (unsigned i=0; i<16; i++) if (counts[i]) fprintf(logfile, "stream=%u total=%u last=%lld\n", i, counts[i], last[i]);
    fprintf(logfile, "GPU textures=%u\n", textures);
    fprintf(logfile, "complete hr=%08lx ended=%u\n", hr, ended);
    /* A timeout can leave a Wine callback blocked; process exit is the test boundary. */
    if (hr == HRESULT_FROM_WIN32(ERROR_TIMEOUT)) { fclose(logfile); return 3; }
    if (reader) IMFSourceReader_Release(reader);
    if (attrs) IMFAttributes_Release(attrs);
    if (manager) IMFDXGIDeviceManager_Release(manager);
    if (device) ID3D11Device_Release(device);
    MFShutdown(); CoUninitialize(); CloseHandle(ready); fclose(logfile);
    return FAILED(hr);
}
