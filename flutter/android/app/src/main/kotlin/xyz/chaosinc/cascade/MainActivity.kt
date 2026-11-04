package xyz.chaosinc.cascade

import com.ryanheise.audioservice.AudioServiceActivity

// audio_service's activity, so playback can live in its foreground service.
class MainActivity : AudioServiceActivity()
