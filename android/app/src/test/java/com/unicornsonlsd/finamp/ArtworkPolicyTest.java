package com.unicornsonlsd.finamp;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.util.Arrays;

public final class ArtworkPolicyTest {
    public static void main(String[] args) throws Exception {
        for (byte[] header : new byte[][]{
                {(byte)137, 80, 78, 71, 13, 10, 26, 10},
                {(byte)255, (byte)216, (byte)255},
                "GIF89a".getBytes(), "RIFF1234WEBP".getBytes(), "BM".getBytes(),
                "II*\0".getBytes(), "MM\0*".getBytes(), "1234ftypavif".getBytes()}) {
            byte[] image = Arrays.copyOf(header, 100);
            assert Arrays.equals(ArtworkPolicy.readImage(new ByteArrayInputStream(image)), image);
        }
        for (String content : new String[]{"{\"token\":\"private\"}", "<?xml version='1.0'?><settings/>",
                "SQLite format 3\0", "1234ftypmp42-private-video", "not an image", ""}) {
            boolean rejected = false;
            try { ArtworkPolicy.readImage(new ByteArrayInputStream(content.getBytes())); }
            catch (IOException expected) { rejected = true; }
            assert rejected : "Non-image data was accepted";
        }
        File image = File.createTempFile("finamp-artwork-check-", ".png");
        try {
            byte[] bytes = Arrays.copyOf("GIF89a".getBytes(), 100);
            Files.write(image.toPath(), bytes);
            ArtworkPolicy.validateFile(image);
            Files.write(image.toPath(), "{\"token\":\"private settings\"}".getBytes());
            boolean rejected = false;
            try { ArtworkPolicy.validateFile(image); }
            catch (IOException expected) { rejected = true; }
            assert rejected : "Private settings disguised as a PNG were accepted";
        } finally {
            Files.deleteIfExists(image.toPath());
        }
        final int[] read = {0};
        InputStream endlessImage = new InputStream() {
            @Override public int read() { return 0; }
            @Override public int read(byte[] buffer, int offset, int length) {
                Arrays.fill(buffer, offset, offset + length, (byte)0);
                if (read[0] == 0) System.arraycopy("GIF89a".getBytes(), 0, buffer, offset, 6);
                read[0] += length;
                return length;
            }
        };
        boolean rejected = false;
        try { ArtworkPolicy.readImage(endlessImage); }
        catch (IOException expected) { rejected = true; }
        assert rejected : "Unbounded artwork was accepted";
        assert read[0] <= ArtworkPolicy.MAX_BYTES + 16384;
        System.out.println("Artwork checks passed: image formats, private-file rejection and bounded reads");
    }
}
