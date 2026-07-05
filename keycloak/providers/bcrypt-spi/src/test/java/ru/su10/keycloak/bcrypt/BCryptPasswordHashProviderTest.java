package ru.su10.keycloak.bcrypt;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;
import org.keycloak.models.credential.PasswordCredentialModel;

import at.favre.lib.crypto.bcrypt.BCrypt;

/**
 * Offline-тесты verify(). bcrypt-хэши генерируются at.favre в рантайме теста — фикстуры с хэшами не
 * коммитим. Кросс-совместимость именно с bcryptjs проверяется отдельно в verify-bcrypt-poc.sh (реальный
 * bcryptjs через node). Все хэши здесь на минимальном cost=4 (кроме явных cost 10/12) — ради скорости.
 */
class BCryptPasswordHashProviderTest {

    private final BCryptPasswordHashProvider provider =
            new BCryptPasswordHashProvider("bcrypt", 12);

    /** Собрать credential в том же виде, в каком его читает verify: secretData.value = полный bcrypt-хэш. */
    private static PasswordCredentialModel cred(String hash) {
        return PasswordCredentialModel.createFromValues("bcrypt", null, 12, hash);
    }

    private static String hash(String raw, int cost) {
        return BCrypt.withDefaults().hashToString(cost, raw.toCharArray());
    }

    /** Заменить префикс версии ($2a → $2b / $2y). Байтово хэш идентичен, verify обязан принимать все три. */
    private static String withVersion(String hash, char version) {
        return "$2" + version + hash.substring(3);
    }

    @Test
    void happyRoundTrip_cost12() {
        String h = hash("S3cret-Passw0rd!", 12);
        assertTrue(provider.verify("S3cret-Passw0rd!", cred(h)));
    }

    @Test
    void happyRoundTrip_cost10() {
        String h = hash("another-pass", 10);
        assertTrue(provider.verify("another-pass", cred(h)));
    }

    @Test
    void wrongPassword() {
        String h = hash("correct-horse", 4);
        assertFalse(provider.verify("wrong-horse", cred(h)));
    }

    @Test
    void malformedHash() {
        assertFalse(provider.verify("whatever", cred("not-a-bcrypt-hash")));
        assertFalse(provider.verify("whatever", cred("$2a$")));
    }

    @Test
    void emptyOrNullSecret() {
        assertFalse(provider.verify("whatever", cred("")));
        assertFalse(provider.verify("whatever", cred(null)));
    }

    @Test
    void nullRawPassword() {
        String h = hash("x", 4);
        assertFalse(provider.verify(null, cred(h)));
    }

    @Test
    void acceptsAllVersionPrefixes_2a_2b_2y() {
        String raw = "cross-version-pw";
        String base = hash(raw, 4); // at.favre выдаёт $2a
        assertTrue(provider.verify(raw, cred(withVersion(base, 'a'))));
        assertTrue(provider.verify(raw, cred(withVersion(base, 'b'))));
        assertTrue(provider.verify(raw, cred(withVersion(base, 'y'))));
    }

    @Test
    void truncatesAt72Bytes_matchesBcryptjs() {
        // bcrypt использует лишь первые 72 байта. Хэш от ровно 72 'a', вход из 80 'a' → те же 72 байта → true.
        String seventyTwo = "a".repeat(72);
        String h = hash(seventyTwo, 4);
        assertTrue(provider.verify("a".repeat(80), cred(h)));
        // Отличие в пределах первых 72 байт → false.
        assertFalse(provider.verify("b".repeat(80), cred(h)));
    }

    @Test
    void unicodePassword_utf8() {
        String raw = "Пароль-Ünïcode-🔐-2026";
        String h = hash(raw, 4);
        assertTrue(provider.verify(raw, cred(h)));
        assertFalse(provider.verify("Пароль-Ünïcode-🔐-2025", cred(h)));
    }

    @Test
    void costGuard_rejectsOutOfRange() {
        // Берём валидный cost-4 хэш и подменяем cost на заведомо вне диапазона [4..16] — verify должен
        // вернуть false, не запуская дорогой bcrypt (guard от CPU-DoS).
        String h = hash("pw", 4);
        String tooHigh = h.substring(0, 4) + "20" + h.substring(6); // $2a$20$...
        String tooLow = h.substring(0, 4) + "03" + h.substring(6);  // $2a$03$...
        assertFalse(provider.verify("pw", cred(tooHigh)));
        assertFalse(provider.verify("pw", cred(tooLow)));
    }
}
