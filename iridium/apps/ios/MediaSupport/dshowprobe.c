#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dshow.h>
#include <stdio.h>

// Checks graph operations. Visible video and audible sync still require observation.
int wmain(int argc, WCHAR **argv) {
    if (argc != 2) return 2;
    FILE *log = fopen("C:\\iridium-dshow-check.log", "w");
    if (!log) return 3;
    setvbuf(log, NULL, _IONBF, 0);
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    const WCHAR *modules[] = {L"quartz.dll", L"devenum.dll", L"winegstreamer.dll"};
    for (unsigned i = 0; i < 3; ++i) {
        HMODULE module = LoadLibraryW(modules[i]);
        HRESULT (WINAPI *reg)(void) = module ? (void *)GetProcAddress(module, "DllRegisterServer") : NULL;
        fprintf(log, "register %ls: %08lx\n", modules[i], reg ? reg() : HRESULT_FROM_WIN32(GetLastError()));
    }
    IGraphBuilder *graph = NULL; IMediaControl *control = NULL;
    IMediaSeeking *seeking = NULL; IMediaEvent *events = NULL;
    HRESULT hr = CoCreateInstance(&CLSID_FilterGraph, NULL, CLSCTX_INPROC_SERVER, &IID_IGraphBuilder, (void **)&graph);
    fprintf(log, "create graph=%08lx\n", hr);
    if (FAILED(hr)) return 4;
    hr = IGraphBuilder_RenderFile(graph, argv[1], NULL);
    fprintf(log, "RenderFile=%08lx\n", hr);
    if (FAILED(hr)) return 5;
    if (FAILED(IGraphBuilder_QueryInterface(graph, &IID_IMediaControl, (void **)&control)) ||
        FAILED(IGraphBuilder_QueryInterface(graph, &IID_IMediaSeeking, (void **)&seeking)) ||
        FAILED(IGraphBuilder_QueryInterface(graph, &IID_IMediaEvent, (void **)&events))) return 6;
    hr = IMediaControl_Run(control); fprintf(log, "Run=%08lx\n", hr);
    Sleep(250);
    hr = IMediaControl_Pause(control); fprintf(log, "Pause=%08lx\n", hr);
    OAFilterState state = State_Stopped;
    hr = IMediaControl_GetState(control, 3000, &state);
    fprintf(log, "Paused state=%ld hr=%08lx\n", state, hr);
    LONGLONG duration = 0;
    hr = IMediaSeeking_GetDuration(seeking, &duration);
    LONGLONG position = duration / 2;
    if (SUCCEEDED(hr)) hr = IMediaSeeking_SetPositions(seeking, &position, AM_SEEKING_AbsolutePositioning, NULL, AM_SEEKING_NoPositioning);
    fprintf(log, "Seek midpoint=%08lx duration=%lld\n", hr, duration);
    hr = IMediaControl_Run(control); fprintf(log, "Resume=%08lx\n", hr);
    LONG event = 0;
    hr = IMediaEvent_WaitForCompletion(events, 60000, &event);
    fprintf(log, "Completion=%08lx event=%ld\n", hr, event);
    HRESULT complete = hr;
    hr = IMediaControl_Stop(control); fprintf(log, "Stop=%08lx\n", hr);
    IMediaEvent_Release(events); IMediaSeeking_Release(seeking);
    IMediaControl_Release(control); IGraphBuilder_Release(graph);
    CoUninitialize(); fclose(log);
    return FAILED(complete) || event != EC_COMPLETE;
}
