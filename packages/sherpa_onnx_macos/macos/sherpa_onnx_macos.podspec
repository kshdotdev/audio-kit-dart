Pod::Spec.new do |spec|
  spec.name = 'sherpa_onnx_macos'
  spec.version = '1.13.4'
  spec.summary = 'macOS 12-compatible sherpa-onnx Flutter FFI binaries.'
  spec.description = <<-DESC
Universal ONNX Runtime and sherpa-onnx dylibs rebuilt from pinned upstream
sources with a real macOS 12.0 deployment target.
                       DESC
  spec.homepage = 'https://github.com/kshdotdev/audio-kit-dart'
  spec.license = { :file => '../LICENSE' }
  spec.author = { 'Concepta' => 'engineering@concepta.dev' }
  spec.source = { :path => '.' }
  spec.dependency 'FlutterMacOS'
  spec.vendored_libraries = '*.dylib'
  spec.platform = :osx, '12.0'
  spec.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'MACOSX_DEPLOYMENT_TARGET' => '12.0'
  }
  spec.swift_version = '5.0'
end
