package ru.su10.keycloak.bcrypt;

import java.nio.charset.StandardCharsets;

import org.keycloak.credential.hash.PasswordHashProvider;
import org.keycloak.models.PasswordPolicy;
import org.keycloak.models.credential.PasswordCredentialModel;

import at.favre.lib.crypto.bcrypt.BCrypt;
import at.favre.lib.crypto.bcrypt.LongPasswordStrategies;

/**
 * PasswordHashProvider с алгоритмом {@code bcrypt} для Keycloak 26.
 *
 * <p>Назначение — исключительно <b>проверка</b> импортированных bcrypt-хэшей (BillHub, библиотека
 * bcryptjs, cost 12) при миграции пользователей в realm su10. Policy realm остаётся дефолтной (argon2):
 * после первого успешного входа Keycloak сам перехэширует пароль в argon2 (см. CREDENTIAL_CONTRACT.md).
 *
 * <p>Соль и cost хранятся внутри самой bcrypt-строки {@code $2[aby]$NN$...}, поэтому отдельное поле
 * {@code salt} в {@code secretData} не используется — {@link #verify} читает полный хэш из
 * {@code secretData.value}.
 */
public class BCryptPasswordHashProvider implements PasswordHashProvider {

    private final String providerId;
    private final int defaultIterations;

    /**
     * Verifyer с усечением пароля до 72 байт — чтобы точно повторить поведение bcryptjs (bcrypt использует
     * лишь первые 72 байта ключа). Дефолтный strict-режим at.favre кидает исключение на паролях >71 байта,
     * что для проверки легаси-хэшей нежелательно. Версию из хэша ($2a/$2b/$2y) non-strict verify определяет сам.
     */
    private static final BCrypt.Verifyer VERIFYER =
            BCrypt.verifyer(BCrypt.Version.VERSION_2A, LongPasswordStrategies.truncate(BCrypt.Version.VERSION_2A));

    // Разумный диапазон cost. Ниже — небезопасно, выше — риск многосекундного verify (CPU-DoS при кривом импорте).
    private static final int MIN_COST = 4;
    private static final int MAX_COST = 16;

    public BCryptPasswordHashProvider(String providerId, int defaultIterations) {
        this.providerId = providerId;
        this.defaultIterations = defaultIterations;
    }

    @Override
    public boolean policyCheck(PasswordPolicy policy, PasswordCredentialModel credential) {
        int policyIterations = policy.getHashIterations();
        if (policyIterations == -1) {
            policyIterations = defaultIterations;
        }
        return providerId.equals(credential.getPasswordCredentialData().getAlgorithm())
                && credential.getPasswordCredentialData().getHashIterations() == policyIterations;
    }

    /**
     * Реализовано для полноты контракта SPI; наш миграционный поток этот метод не использует
     * (bcrypt-хэши приходят готовыми из BillHub через partialImport).
     */
    @Override
    public PasswordCredentialModel encodedCredential(String rawPassword, int iterations) {
        if (iterations <= 0) {
            iterations = defaultIterations;
        }
        String encoded = BCrypt.withDefaults().hashToString(iterations, rawPassword.toCharArray());
        // Соль внутри строки хэша → отдельное поле salt не нужно (null, а не пустой массив).
        return PasswordCredentialModel.createFromValues(providerId, null, iterations, encoded);
    }

    @Override
    public boolean verify(String rawPassword, PasswordCredentialModel credential) {
        if (rawPassword == null) {
            return false;
        }
        String hash = credential.getPasswordSecretData().getValue();
        if (hash == null || hash.isEmpty()) {
            return false;
        }
        int cost = parseCost(hash);
        if (cost < MIN_COST || cost > MAX_COST) {
            // Битый префикс или cost вне разумного диапазона — не запускаем verify.
            return false;
        }
        BCrypt.Result result = VERIFYER.verify(
                rawPassword.getBytes(StandardCharsets.UTF_8),
                hash.getBytes(StandardCharsets.UTF_8));
        return result.verified;
    }

    /**
     * Достаёт cost из префикса bcrypt-строки {@code $2a$NN$...} (NN — две цифры на позициях 4..5).
     * @return распарсенный cost или {@code -1}, если формат не распознан.
     */
    private static int parseCost(String hash) {
        // Минимальный валидный префикс: "$2a$12$" (7 символов), версия — 2 символа, cost — 2 цифры.
        if (hash.length() < 7 || hash.charAt(0) != '$' || hash.charAt(1) != '2'
                || hash.charAt(3) != '$' || hash.charAt(6) != '$') {
            return -1;
        }
        char c1 = hash.charAt(4);
        char c2 = hash.charAt(5);
        if (c1 < '0' || c1 > '9' || c2 < '0' || c2 > '9') {
            return -1;
        }
        return (c1 - '0') * 10 + (c2 - '0');
    }

    @Override
    public void close() {
        // no-op
    }
}
