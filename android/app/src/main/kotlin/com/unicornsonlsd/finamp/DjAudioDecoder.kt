package com.unicornsonlsd.finamp

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Decodes a short recording the listener imports (an MP3, M4A or AAC) with the phone's own decoders, to a WAV. */
object DjAudioDecoder {
    /**
     * Writes [input] to [output] as a 16-bit PCM WAV, at its own rate and channels. Only the first [maxSeconds] and a
     * second more are decoded, so a long file is turned down as too long without decoding it all.
     */
    fun decode(input: String, output: String, maxSeconds: Int) {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(input)
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: throw IllegalArgumentException("No sound in the file")
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            val decoder = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            codec = decoder
            decoder.configure(format, null, null, 0)
            decoder.start()
            var rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var float = false
            val pcm = ByteArrayOutputStream()
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            // A decoder that never says it's done doesn't hold the import up for ever.
            val deadline = System.currentTimeMillis() + 30_000
            while (true) {
                if (System.currentTimeMillis() > deadline) throw IllegalStateException("Decoding took too long")
                if (!inputDone) {
                    val index = decoder.dequeueInputBuffer(10_000)
                    if (index >= 0) {
                        val size = extractor.readSampleData(decoder.getInputBuffer(index)!!, 0)
                        if (size < 0) {
                            decoder.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            decoder.queueInputBuffer(index, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val index = decoder.dequeueOutputBuffer(info, 10_000)
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val decoded = decoder.outputFormat
                    rate = decoded.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    channels = decoded.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    float = decoded.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                        decoded.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
                } else if (index >= 0) {
                    val buffer = decoder.getOutputBuffer(index)!!
                    buffer.position(info.offset)
                    buffer.limit(info.offset + info.size)
                    val bytes = ByteArray(info.size)
                    buffer.get(bytes)
                    pcm.write(if (float) toInt16(bytes) else bytes)
                    decoder.releaseOutputBuffer(index, false)
                    val ended = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    if (ended || pcm.size() > (maxSeconds + 1) * rate * channels * 2) break
                }
            }
            File(output).writeBytes(wav(pcm.toByteArray(), rate, channels))
        } finally {
            codec?.let {
                runCatching { it.stop() }
                it.release()
            }
            extractor.release()
        }
    }

    /** 32-bit float samples as 16-bit ones. */
    private fun toInt16(bytes: ByteArray): ByteArray {
        val floats = ByteBuffer.wrap(bytes).order(ByteOrder.nativeOrder()).asFloatBuffer()
        val out = ByteBuffer.allocate(floats.remaining() * 2).order(ByteOrder.LITTLE_ENDIAN)
        while (floats.hasRemaining()) {
            out.putShort((floats.get().coerceIn(-1f, 1f) * 32767).toInt().toShort())
        }
        return out.array()
    }

    private fun wav(pcm: ByteArray, rate: Int, channels: Int): ByteArray {
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        header.put("RIFF".toByteArray()).putInt(36 + pcm.size).put("WAVE".toByteArray())
        header.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(channels.toShort())
        header.putInt(rate).putInt(rate * channels * 2).putShort((channels * 2).toShort()).putShort(16)
        header.put("data".toByteArray()).putInt(pcm.size)
        return header.array() + pcm
    }
}
