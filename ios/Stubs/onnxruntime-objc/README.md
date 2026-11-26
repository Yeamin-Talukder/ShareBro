# onnxruntime-objc stand-in

An empty pod that takes the place of Microsoft's `onnxruntime-objc` 1.15.1
on iOS. The `onnxruntime` Flutter plugin depends on it, but its library
(`onnxruntime-c`) can no longer be downloaded, and the iPhone app never
runs ONNX: phones find faces with ML Kit and TensorFlow Lite. ONNX Runtime
is only used by the desktop apps.

Remove this folder and the line in `ios/Podfile` if the plugin is ever
upgraded to an ONNX Runtime that can be downloaded, or removed on iOS.
