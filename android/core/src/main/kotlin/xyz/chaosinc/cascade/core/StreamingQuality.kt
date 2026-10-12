package xyz.chaosinc.cascade.core

/**
 * The most the server may stream, as a user picks it in Settings. The same
 * steps as the desktop's Max streaming bitrate, plus 256 kbps, and the same
 * stored values as the Apple app (`cascade.streamingQuality`, an Int).
 *
 * Anything below the source's bitrate makes the server transcode to AAC at
 * that rate, which is the point on a metered connection. Original means the
 * device profile's own ceiling, which every music file sits under.
 */
enum class StreamingQuality(val raw: Int) {
    Original(0), Kbps320(320_000), Kbps256(256_000), Kbps192(192_000), Kbps128(128_000), Kbps96(96_000);

    /** Bits per second to ask for, or null to leave the profile's own limit. */
    val bitrate: Long? get() = if (this == Original) null else raw.toLong()

    val label: String get() = if (this == Original) "Original" else "${raw / 1000} kbps"

    companion object {
        const val WIFI_KEY = "cascade.streamingQuality"
        const val CELLULAR_KEY = "cascade.cellularStreamingQuality"

        /** The desktop's "Original" (src/core/jellyfin.ts DEFAULT_MAX_BITRATE). */
        const val DESKTOP_ORIGINAL = 140_000_000L

        /**
         * A stored value is untrusted: an old build or a bad write must land on
         * a real step, never reach the server as a made-up bitrate.
         */
        fun fromStored(value: Any?): StreamingQuality =
            entries.firstOrNull { it.raw == (value as? Int) } ?: Original

        /**
         * The desktop's `maxStreamingBitrate`, bits per second with 140,000,000
         * as Original. A value between two steps lands on the step below it, so
         * a cap is never loosened by the mapping.
         */
        fun fromElectronBitrate(value: Any?): StreamingQuality {
            val number = (value as? Number)?.toLong() ?: (value as? String)?.toLongOrNull() ?: 0L
            if (number <= 0 || number >= DESKTOP_ORIGINAL) return Original
            return entries.filter { it.bitrate != null && it.raw <= number }.maxByOrNull { it.raw } ?: Kbps96
        }
    }
}
