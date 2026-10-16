package xyz.chaosinc.cascade.android.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Secrets (the access token, proxy headers) encrypted with a key that lives in
 * the Android Keystore and never leaves it. A Jellyfin token is a bearer
 * credential for the whole account, so it gets the treatment a password would:
 * the preferences file only ever holds ciphertext, which is useless off this
 * device (backups included). AES-GCM, a fresh IV per write.
 *
 * Written against the platform Keystore rather than androidx.security's
 * EncryptedSharedPreferences, which is deprecated.
 */
class SecureStore(context: Context) {
    private val prefs = context.getSharedPreferences("cascade.secure", Context.MODE_PRIVATE)

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build())
        return generator.generateKey()
    }

    fun set(name: String, value: String?) {
        if (value == null) { prefs.edit().remove(name).apply(); return }
        val cipher = Cipher.getInstance(TRANSFORM).apply { init(Cipher.ENCRYPT_MODE, key()) }
        val sealed = cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        prefs.edit().putString(name, Base64.encodeToString(sealed, Base64.NO_WRAP)).apply()
    }

    /**
     * Null when absent, and when it cannot be opened (the key was wiped, as a
     * restore onto a new device does): then the person signs in again rather
     * than the app crashing on a value it can no longer read.
     */
    fun get(name: String): String? = runCatching {
        val sealed = Base64.decode(prefs.getString(name, null) ?: return null, Base64.NO_WRAP)
        val cipher = Cipher.getInstance(TRANSFORM)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, sealed, 0, IV_LENGTH))
        String(cipher.doFinal(sealed, IV_LENGTH, sealed.size - IV_LENGTH), Charsets.UTF_8)
    }.getOrNull()

    companion object {
        private const val ALIAS = "cascade.secrets"
        private const val TRANSFORM = "AES/GCM/NoPadding"
        private const val IV_LENGTH = 12
        const val TOKEN = "token"
        const val PROXY_HEADERS = "proxyHeaders"
    }
}
