package xyz.chaosinc.cascade.android

import android.app.Application
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.disk.DiskCache
import coil3.disk.directory
import coil3.memory.MemoryCache
import coil3.network.okhttp.OkHttpNetworkFetcherFactory
import coil3.request.crossfade

class CascadeApp : Application(), SingletonImageLoader.Factory {
    override fun onCreate() {
        super.onCreate()
        instance = this
        state = AppState(this)
    }

    /**
     * Artwork goes through the app's own HTTP client, so a server behind a
     * reverse proxy gets its headers on image requests too, with a disk cache
     * that keeps covers across launches.
     */
    override fun newImageLoader(context: PlatformContext): ImageLoader = ImageLoader.Builder(context)
        .components { add(OkHttpNetworkFetcherFactory(callFactory = { state.http })) }
        .memoryCache { MemoryCache.Builder().maxSizePercent(context, 0.2).build() }
        .diskCache { DiskCache.Builder().directory(context.cacheDir.resolve("artwork")).maxSizeBytes(256L * 1024 * 1024).build() }
        .crossfade(true)
        .build()

    companion object {
        lateinit var instance: CascadeApp
            private set
        lateinit var state: AppState
            private set
    }
}
