package ru.su10.keycloak.bcrypt;

import org.keycloak.credential.hash.PasswordHashProvider;
import org.keycloak.credential.hash.PasswordHashProviderFactory;
import org.keycloak.models.KeycloakSession;

/**
 * Фабрика {@link BCryptPasswordHashProvider}. {@code getId() == "bcrypt"} — по этому id Keycloak
 * выбирает провайдер при проверке credential с {@code credentialData.algorithm == "bcrypt"}.
 */
public class BCryptPasswordHashProviderFactory implements PasswordHashProviderFactory {

    public static final String ID = "bcrypt";

    /** cost по умолчанию для BillHub (bcryptjs). Используется только в encodedCredential/policyCheck. */
    public static final int DEFAULT_ITERATIONS = 12;

    @Override
    public PasswordHashProvider create(KeycloakSession session) {
        return new BCryptPasswordHashProvider(ID, DEFAULT_ITERATIONS);
    }

    @Override
    public String getId() {
        return ID;
    }
}
