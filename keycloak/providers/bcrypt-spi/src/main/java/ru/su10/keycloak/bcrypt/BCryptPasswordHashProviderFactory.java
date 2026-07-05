package ru.su10.keycloak.bcrypt;

import org.keycloak.Config;
import org.keycloak.credential.hash.PasswordHashProvider;
import org.keycloak.credential.hash.PasswordHashProviderFactory;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;

/**
 * Фабрика {@link BCryptPasswordHashProvider}. {@code getId() == "bcrypt"} — по этому id Keycloak
 * выбирает провайдер при проверке credential с {@code credentialData.algorithm == "bcrypt"}.
 *
 * <p>init/postInit/close — no-op: провайдер stateless, глобальный конфиг/ресурсы ему не нужны.
 * В {@code org.keycloak.provider.ProviderFactory} (KC 26.1.5) эти три метода абстрактные, поэтому
 * реализованы явно.
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
    public void init(Config.Scope config) {
        // no-op
    }

    @Override
    public void postInit(KeycloakSessionFactory factory) {
        // no-op
    }

    @Override
    public void close() {
        // no-op
    }

    @Override
    public String getId() {
        return ID;
    }
}
