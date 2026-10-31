package com.unicornsonlsd.finamp;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

/** Only bounded image data may be shared by the media artwork provider. */
public final class ArtworkPolicy {
    public static final int MAX_BYTES = 32 * 1024 * 1024;

    private ArtworkPolicy() {}

    public static void validateFile(File file) throws IOException {
        long length = file.length();
        if (!file.isFile() || length < 12 || length > MAX_BYTES) {
            throw new IOException("Artwork is missing or too large");
        }
        byte[] header = new byte[32];
        int count = 0;
        try (InputStream input = new FileInputStream(file)) {
            while (count < header.length) {
                int read = input.read(header, count, header.length - count);
                if (read < 0) break;
                count += read;
            }
        }
        if (!isImage(header, count)) throw new IOException("Not supported artwork");
    }

    public static byte[] readImage(InputStream input) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        byte[] buffer = new byte[16 * 1024];
        int total = 0;
        boolean checkedHeader = false;
        for (int count; (count = input.read(buffer)) != -1;) {
            total += count;
            if (total > MAX_BYTES) throw new IOException("Artwork is too large");
            output.write(buffer, 0, count);
            if (!checkedHeader && total >= 32) {
                if (!isImage(output.toByteArray(), total)) throw new IOException("Not supported artwork");
                checkedHeader = true;
            }
        }
        byte[] result = output.toByteArray();
        if (!isImage(result, result.length)) throw new IOException("Not supported artwork");
        return result;
    }

    static boolean isImage(byte[] bytes, int length) {
        if (length < 12) return false;
        if ((bytes[0] & 255) == 255 && (bytes[1] & 255) == 216 && (bytes[2] & 255) == 255) return true;
        if ((bytes[0] & 255) == 137 && ascii(bytes, 1, "PNG\r\n\u001a\n")) return true;
        if (ascii(bytes, 0, "GIF87a") || ascii(bytes, 0, "GIF89a")) return true;
        if (ascii(bytes, 0, "RIFF") && ascii(bytes, 8, "WEBP")) return true;
        if (ascii(bytes, 0, "BM") || ascii(bytes, 0, "II*\0") || ascii(bytes, 0, "MM\0*")) return true;
        if (ascii(bytes, 4, "ftyp")) {
            for (String brand : new String[]{"avif", "avis", "heic", "heix", "hevc", "hevx", "mif1", "msf1"}) {
                if (ascii(bytes, 8, brand)) return true;
            }
        }
        return false;
    }

    private static boolean ascii(byte[] bytes, int offset, String text) {
        byte[] expected = text.getBytes(StandardCharsets.US_ASCII);
        if (offset + expected.length > bytes.length) return false;
        for (int i = 0; i < expected.length; i++) if (bytes[offset + i] != expected[i]) return false;
        return true;
    }
}
