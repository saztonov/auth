import type { User } from 'oidc-client-ts';

// Inline-SVG разметка иконки портала (монохром через `currentColor` — наследует цвет темы).
// ВНИМАНИЕ: это плейсхолдеры под реальные лого порталов — заменить на фирменные знаки EstiMat/BillHub.
type IconSvg = string;

// Плейсхолдер EstiMat: линейка/чертёж (сметы, ВОР).
const ICON_ESTIMAT: IconSvg =
  '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="2" y="8" width="20" height="8" rx="1.5"/><path d="M6 8v3M10 8v4M14 8v3M18 8v4"/></svg>';

// Плейсхолдер BillHub: квитанция/платёж (договоры, платежи).
const ICON_BILLHUB: IconSvg =
  '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M6 3.5h12V20l-2-1.3-2 1.3-2-1.3-2 1.3-2-1.3-2 1.3V3.5Z"/><path d="M9 8h6M9 12h6"/></svg>';

// Портал контура su10. Гейт плитки — ОДИН из двух (по факту доступа на самом портале):
// - requiredRole "<clientId>:<role>" — портал без своей БД пользователей, гейтит client-ролью
//   (эталон EstiMat: resource_access.estimat.roles).
// - requiredGroup "<имя>" — портал с провижинингом/активацией через группы Keycloak
//   (эталон BillHub: членство в billhub-active).
export interface Portal {
  id: string;
  name: string;
  description: string;
  url: string;
  icon: IconSvg; // inline-SVG (currentColor); плейсхолдер под реальное лого портала
  requiredRole?: string;
  requiredGroup?: string;
}

export const PORTALS: Portal[] = [
  {
    id: 'estimat',
    name: 'EstiMat',
    description: 'Сметный портал — сметы, ВОР, справочники',
    url: 'https://estimat.su10.ru',
    icon: ICON_ESTIMAT,
    requiredRole: 'estimat:access',
  },
  {
    id: 'billhub',
    name: 'BillHub',
    description: 'Портал платежей и договоров',
    url: 'https://rp.su10.ru',
    icon: ICON_BILLHUB,
    requiredGroup: 'billhub-active',
  },
];

// Доступность плитки портала.
//
// v2 = фильтрация по реальным правам. Клиенту `su10-launcher` в su10-realm.yaml добавлены мапперы
// resource_access.estimat.roles + groups (id.token.claim — эта SPA не делает loadUserInfo, user.profile
// берётся только из id_token). Раз мапперы задеплоены — отсутствие требуемой роли/группы в токене
// значит ОТКАЗ (fail-closed), а не "данные ещё не пришли": v1 показывал все плитки всем именно потому,
// что мапперов не было вообще (см. git-историю), сейчас это уже не так.
export function hasPortalAccess(user: User | null | undefined, portal: Portal): boolean {
  const profile = user?.profile as Record<string, unknown> | undefined;

  if (portal.requiredRole) {
    const [client, role] = portal.requiredRole.split(':');
    const resourceAccess = profile?.['resource_access'] as
      | Record<string, { roles?: string[] }>
      | undefined;
    return (resourceAccess?.[client]?.roles ?? []).includes(role);
  }

  if (portal.requiredGroup) {
    const groups = profile?.['groups'] as string[] | undefined;
    return (groups ?? []).includes(portal.requiredGroup);
  }

  return true;
}
