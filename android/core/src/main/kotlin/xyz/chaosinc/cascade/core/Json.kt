package xyz.chaosinc.cascade.core

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNamingStrategy

// Jellyfin's JSON is PascalCase throughout ("ItemId", "PlaySessionId"). Kotlin
// properties are lowerCamelCase. Rather than an @SerialName on every field,
// which is where key-mapping bugs live, the whole difference is one rule
// applied by this one Json instance: flip the case of the first character.
// It is the same rule CascadeKit's JSON.swift applies, so the two apps read
// and write identical shapes.
//
// Use `CascadeJson` for anything on the wire, never a bare Json {}.

@OptIn(ExperimentalSerializationApi::class)
private object PascalCase : JsonNamingStrategy {
    override fun serialNameForJson(descriptor: SerialDescriptor, elementIndex: Int, serialName: String): String =
        serialName.replaceFirstChar { it.uppercaseChar() }
}

@OptIn(ExperimentalSerializationApi::class)
val CascadeJson: Json = Json {
    namingStrategy = PascalCase
    // The server sends far more than these models read.
    ignoreUnknownKeys = true
    // Leave nulls out of what is sent, as Swift's encoder does: some
    // endpoints read an explicit null differently from a missing field.
    explicitNulls = false
    // A field of the wrong type (an older server, a plugin) reads as its
    // default rather than failing the whole response.
    coerceInputValues = true
    isLenient = true
}

/** For third-party and stored JSON whose keys are not Jellyfin's (LRCLIB, saved prefs). */
val PlainJson: Json = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
}
