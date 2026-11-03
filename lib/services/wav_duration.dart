import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Times a PCM WAV without reading its audio or copying it into another buffer.
/// Metadata chunks are skipped by seeking, including their RIFF padding byte.
Future<Duration?> wavFileDuration(File file) async {
  final input = await file.open();
  try {
    final length = await input.length();
    if (length < 44) return null;
    final header = await input.read(12);
    if (header.length != 12 ||
        String.fromCharCodes(header.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(header.sublist(8, 12)) != 'WAVE') {
      return null;
    }
    int? byteRate;
    for (var offset = 12; offset + 8 <= length;) {
      await input.setPosition(offset);
      final chunk = await input.read(8);
      if (chunk.length != 8) return null;
      final id = String.fromCharCodes(chunk.sublist(0, 4));
      final size = ByteData.sublistView(chunk).getUint32(4, Endian.little);
      if (id == 'fmt ') {
        if (size < 12 || offset + 20 > length) return null;
        final format = await input.read(12);
        if (format.length != 12) return null;
        byteRate = ByteData.sublistView(format).getUint32(8, Endian.little);
      }
      if (id == 'data') {
        if (byteRate == null || byteRate == 0) return null;
        final available = min(size, length - offset - 8);
        return Duration(microseconds: available * Duration.microsecondsPerSecond ~/ byteRate);
      }
      offset += 8 + size + size % 2;
    }
    return null;
  } finally {
    await input.close();
  }
}
