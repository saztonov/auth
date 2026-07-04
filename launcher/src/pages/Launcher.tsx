import { useAuth } from 'react-oidc-context';
import { PORTALS, hasPortalAccess } from '../config/portals';
import { accountConsoleUrl } from '../auth/oidc';

export function Launcher() {
  const auth = useAuth();
  const user = auth.user ?? null;
  const name =
    (user?.profile?.name as string | undefined) ??
    (user?.profile?.preferred_username as string | undefined) ??
    (user?.profile?.email as string | undefined) ??
    'пользователь';

  const portals = PORTALS.filter((p) => hasPortalAccess(user, p));

  return (
    <div className="launcher">
      <header className="launcher__header">
        <div className="launcher__brand">СУ_10 · порталы</div>
        <div className="launcher__user">
          <span className="launcher__name">{name}</span>
          <a className="launcher__link" href={accountConsoleUrl} target="_blank" rel="noreferrer">
            Сменить пароль / MFA
          </a>
          <button
            className="launcher__logout"
            onClick={() => void auth.signoutRedirect()}
          >
            Выйти
          </button>
        </div>
      </header>

      <main className="launcher__grid">
        {portals.length === 0 && (
          <p className="launcher__empty">Нет доступных порталов. Обратитесь к администратору.</p>
        )}
        {portals.map((p) => (
          <a key={p.id} className="tile" href={p.url}>
            {/* Иконка — статичная inline-SVG из config/portals (не пользовательский ввод,
                поэтому безопасно). Плейсхолдер под реальное лого портала. */}
            <span
              className="tile__icon"
              aria-hidden
              dangerouslySetInnerHTML={{ __html: p.icon }}
            />
            <span className="tile__name">{p.name}</span>
            <span className="tile__desc">{p.description}</span>
          </a>
        ))}
      </main>
    </div>
  );
}
