# ONNX Runtime with DirectML (Windows x64)

`onnxruntime.dll` from Microsoft's NuGet package
**Microsoft.ML.OnnxRuntime.DirectML 1.24.4**
(`runtimes/win-x64/native/onnxruntime.dll`), unchanged.

- Package SHA-512 (as published on nuget.org):
  `ZjOyv495vhfVXoTJp2utRyn8ir1TFIvCj0B9JP8QZGBXS0oFx+lY7ZCZqSdnVShQX6EtxYi2T3VOtYXcmBTV4A==`
- The DLL is Authenticode-signed by Microsoft Corporation.
- Licence: MIT (`LICENSE`); third-party notices in `ThirdPartyNotices.txt`.

`windows/CMakeLists.txt` installs it over the `onnxruntime` plugin's
CPU-only DLL. `lib/face/ort_lite.dart` turns DirectML on through
`OrtSessionOptionsAppendExecutionProvider_DML` and falls back to the CPU
when the PC can't use it. DirectML itself (`DirectML.dll`) comes with
Windows; it isn't bundled.

To update: download the new package from nuget.org, check its hash against
nuget.org's catalog, and replace `onnxruntime.dll`, `LICENSE` and
`ThirdPartyNotices.txt`.
