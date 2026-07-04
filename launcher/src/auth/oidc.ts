import { WebStorageStateStore } from 'oidc-client-ts';
import type { AuthProviderProps } from 'react-oidc-context';

// Конфиг OIDC-клиента su10-launcher (public, Authorization Code + PKCE).
// authority — realm su10; redirect/post-logout — origin витрины (auth.su10.ru или localhost:5173).
const authority = import.meta.env.VITE_OIDC_AUTHORITY ?? 'https://auth.su10.ru/realms/su10';
const clientId = import.meta.env.VITE_OIDC_CLIENT_ID ?? 'su10-launcher';
const origin = window.location.origin;

export const oidcConfig: AuthProviderProps = {
  authority,
  client_id: clientId,
  redirect_uri: `${origin}/`,
  post_logout_redirect_uri: `${origin}/`,
  response_type: 'code',
  scope: 'openid profile email',
  // Токены в sessionStorage: закрытие вкладки завершает клиентскую сессию (SSO держит Keycloak).
  userStore: new WebStorageStateStore({ store: window.sessionStorage }),
  // Чистим query (?code=...&state=...) из адресной строки после успешного callback.
  onSigninCallback: () => {
    window.history.replaceState({}, document.title, window.location.pathname);
  },
};

// Прямая ссылка на Account Console (смена пароля / MFA / сессии).
export const accountConsoleUrl = `${authority}/account`;
