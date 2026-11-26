# An empty stand-in for Microsoft's ONNX Runtime pod.
#
# The onnxruntime Flutter plugin asks for onnxruntime-objc 1.15.1 on iOS,
# whose library (onnxruntime-c) can no longer be downloaded: its archive
# address now returns 404. The iPhone app never runs ONNX (phones find
# faces with ML Kit and TensorFlow Lite; ONNX is only for the desktop
# apps), so nothing is linked in its place. See the Podfile.
Pod::Spec.new do |s|
  s.name         = 'onnxruntime-objc'
  s.version      = '1.15.1'
  s.summary      = 'Empty stand-in: ShareBro does not use ONNX Runtime on iOS.'
  s.homepage     = 'https://github.com/Yeamin-Talukder/ShareBro'
  s.license      = { :type => 'MIT', :text => 'Empty placeholder, no code.' }
  s.author       = 'ShareBro'
  s.source       = { :git => 'https://github.com/Yeamin-Talukder/ShareBro.git' }
  s.platform     = :ios, '15.5'
  # CocoaPods refuses a pod with no files at all.
  s.preserve_paths = 'README.md'
end
