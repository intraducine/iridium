# Host XInput regression test

This standalone test includes the real XInput implementation and supplies a
synthetic host-query import. It runs on Windows without Wine, an iOS device or
a physical controller. It does not install or replace any DLL.

From this repository, with llvm-mingw on PATH and Wine's generated headers in
`build/include` (adjust that path for your configured build):

```sh
x86_64-w64-mingw32-clang -O2 -D__WINESRC__ -Iinclude -Ibuild/include \
  tools/tests/xinput-host.c -lhid -lsetupapi -ladvapi32 -luser32 \
  -o xinput-host-test.exe
```

Run `xinput-host-test.exe` on Windows. The test checks state/capability mapping,
Guide-button filtering, keystroke edges, XInputEnable, invalid arguments,
unknown battery reporting, and per-user audio/disconnect results. It does not
exercise the HID fallback or prove device compatibility.

The iOS `ios_gamepad_query` implementation is supplied by Madeira. The paired
Madeira change must be built together with this Wine change, including the
win32u and XInput PE DLLs; updating only the app does not update those DLLs.
