import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// This app's version on Windows ("1.8.0"), read from the version stamped
/// into the .exe at build time (Flutter takes it from pubspec.yaml). Null
/// when it can't be read.
String? windowsAppVersion() {
  if (!Platform.isWindows) return null;
  try {
    final lib = DynamicLibrary.open('version.dll');
    final sizeOf = lib.lookupFunction<Uint32 Function(Pointer<Utf16>, Pointer<Uint32>),
        int Function(Pointer<Utf16>, Pointer<Uint32>)>('GetFileVersionInfoSizeW');
    final read = lib.lookupFunction<Int32 Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Void>),
        int Function(Pointer<Utf16>, int, int, Pointer<Void>)>('GetFileVersionInfoW');
    final query = lib.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Utf16>, Pointer<Pointer<Void>>, Pointer<Uint32>),
        int Function(Pointer<Void>, Pointer<Utf16>, Pointer<Pointer<Void>>, Pointer<Uint32>)>('VerQueryValueW');

    return using((arena) {
      final path = Platform.resolvedExecutable.toNativeUtf16(allocator: arena);
      final handle = arena<Uint32>();
      final size = sizeOf(path, handle);
      if (size == 0) return null;
      final data = arena<Uint8>(size).cast<Void>();
      if (read(path, 0, size, data) == 0) return null;
      final info = arena<Pointer<Void>>();
      final len = arena<Uint32>();
      if (query(data, r'\'.toNativeUtf16(allocator: arena), info, len) == 0 || len.value == 0) return null;
      // VS_FIXEDFILEINFO: signature, struct version, then the file version
      // as two 32-bit halves (major.minor, patch.build).
      final fixed = info.value.cast<Uint32>();
      if (fixed[0] != 0xFEEF04BD) return null;
      final ms = fixed[2], ls = fixed[3];
      return '${ms >> 16}.${ms & 0xFFFF}.${ls >> 16}';
    });
  } catch (_) {
    return null;
  }
}
