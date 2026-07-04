import { useEffect } from 'react';
import { useAuth } from 'react-oidc-context';
import { Launcher } from './pages/Launcher';

export function App() {
  const auth = useAuth();

  // Нет сессии и не идёт вход/редирект — уводим на страницу входа Keycloak.
  useEffect(() => {
    if (!auth.isLoading && !auth.isAuthenticated && !auth.activeNavigator && !auth.error) {
      void auth.signinRedirect();
    }
  }, [auth.isLoading, auth.isAuthenticated, auth.activeNavigator, auth.error, auth]);

  if (auth.error) {
    return (
      <div className="state state--error">
        <p>Ошибка входа: {auth.error.message}</p>
        <button onClick={() => void auth.signinRedirect()}>Повторить</button>
      </div>
    );
  }

  if (auth.isLoading || !auth.isAuthenticated) {
    return <div className="state">Перенаправление на вход…</div>;
  }

  return <Launcher />;
}
