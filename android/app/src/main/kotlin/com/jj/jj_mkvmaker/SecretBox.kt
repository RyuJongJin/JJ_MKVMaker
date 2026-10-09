package com.jj.jj_mkvmaker

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/// 비밀 값 (WebDAV · OpenSubtitles 비밀번호 등) 을 AndroidKeyStore 의 AES-GCM 키로 암호화해 앱 전용 SharedPreferences ("jj_secrets") 에 둔다.
/// 키는 이 기기 밖으로 나가지 않는다 (백업에서도 제외 - res/xml/backup_rules.xml). 풀지 못한 값은 지우지 않고 건너뛴다.
object SecretBox {
    private const val ALIAS = "jj_secrets"
    private const val PREFS = "jj_secrets"

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    private fun prefs(c: Context) = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun readAll(c: Context): Map<String, String> {
        val all = prefs(c).all
        if (all.isEmpty()) return emptyMap()
        val k = key()
        val out = HashMap<String, String>()
        for ((name, v) in all) {
            val raw = try { Base64.decode(v as String, Base64.NO_WRAP) } catch (_: Exception) { continue }
            if (raw.size < 13) continue
            try {
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.DECRYPT_MODE, k, GCMParameterSpec(128, raw, 0, 12))
                out[name] = String(cipher.doFinal(raw, 12, raw.size - 12), Charsets.UTF_8)
            } catch (_: Exception) {
            }
        }
        return out
    }

    fun write(c: Context, name: String, value: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val body = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val raw = cipher.iv + body
        if (!prefs(c).edit().putString(name, Base64.encodeToString(raw, Base64.NO_WRAP)).commit()) {
            throw IllegalStateException("secret write failed")
        }
    }

    fun delete(c: Context, name: String) {
        prefs(c).edit().remove(name).commit()
    }
}
