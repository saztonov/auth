package ru.su10.keycloak.bcrypt;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

import at.favre.lib.crypto.bcrypt.BCrypt;

/**
 * Offline-тесты ядра проверки {@link BCryptPasswordHashProvider#verifyRaw(String, String)}.
 * bcrypt-хэши генерируются at.favre в рантайме теста — фикстуры с хэшами не коммитим. Тест не касается
 * классов модели Keycloak (jboss-logging/Jackson не нужны). Кросс-совместимость именно с bcryptjs
 * проверяется в verify-bcrypt-poc.sh (реальный bcryptjs через node). Хэши на минимальном cost=4 (кроме
 * явных cost 10/12) — ради скорости.
 */
class BCryptPasswordHashProviderTest {

    private final BCryptPasswordHashProvider provider =
            new BCryptPasswordHashProvider("bcrypt", 12);

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
        assertTrue(provider.verifyRaw("S3cret-Passw0rd!", h));
    }

    @Test
    void happyRoundTrip_cost10() {
        String h = hash("another-pass", 10);
        assertTrue(provider.verifyRaw("another-pass", h));
    }

    @Test
    void wrongPassword() {
        String h = hash("correct-horse", 4);
        assertFalse(provider.verifyRaw("wrong-horse", h));
    }

    @Test
    void malformedHash() {
        assertFalse(provider.verifyRaw("whatever", "not-a-bcrypt-hash"));
        assertFalse(provider.verifyRaw("whatever", "$2a$"));
    }

    @Test
    void emptyOrNullSecret() {
        assertFalse(provider.verifyRaw("whatever", ""));
        assertFalse(provider.verifyRaw("whatever", null));
    }

    @Test
    void nullRawPassword() {
        String h = hash("x", 4);
        assertFalse(provider.verifyRaw(null, h));
    }

    @Test
    void acceptsAllVersionPrefixes_2a_2b_2y() {
        String raw = "cross-version-pw";
        String base = hash(raw, 4); // at.favre выдаёт $2a
        assertTrue(provider.verifyRaw(raw, withVersion(base, 'a')));
        assertTrue(provider.verifyRaw(raw, withVersion(base, 'b')));
        assertTrue(provider.verifyRaw(raw, withVersion(base, 'y')));
    }

    @Test
    void truncatesAt72Bytes_matchesBcryptjs() {
        // bcrypt использует лишь первые 72 байта. Хэш от ровно 72 'a', вход из 80 'a' → те же 72 байта → true.
        String seventyTwo = "a".repeat(72);
        String h = hash(seventyTwo, 4);
        assertTrue(provider.verifyRaw("a".repeat(80), h));
        // Отличие в пределах первых 72 байт → false.
        assertFalse(provider.verifyRaw("b".repeat(80), h));
    }

    @Test
    void unicodePassword_utf8() {
        String raw = "Пароль-Ünïcode-🔐-2026";
        String h = hash(raw, 4);
        assertTrue(provider.verifyRaw(raw, h));
        assertFalse(provider.verifyRaw("Пароль-Ünïcode-🔐-2025", h));
    }

    @Test
    void costGuard_rejectsOutOfRange() {
        // Берём валидный cost-4 хэш и подменяем cost на заведомо вне диапазона [4..16] — verify должен
        // вернуть false, не запуская дорогой bcrypt (guard от CPU-DoS).
        String h = hash("pw", 4);
        String tooHigh = h.substring(0, 4) + "20" + h.substring(6); // $2a$20$...
        String tooLow = h.substring(0, 4) + "03" + h.substring(6);  // $2a$03$...
        assertFalse(provider.verifyRaw("pw", tooHigh));
        assertFalse(provider.verifyRaw("pw", tooLow));
    }
}
