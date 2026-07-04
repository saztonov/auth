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

// Портал контура su10. requiredRole — опциональный гейт: client-роль вида "<clientId>:<role>",
// например "estimat:access". Точная фильтрация плиток по этому полю появится отдельным шагом
// (см. hasPortalAccess ниже); сейчас витрина работает в режиме show-all.
export interface Portal {
  id: string;
  name: string;
  description: string;
  url: string;
  icon: IconSvg; // inline-SVG (currentColor); плейсхолдер под реальное лого портала
  requiredRole?: string;
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
    requiredRole: 'billhub:access',
  },
];

// Доступность плитки портала.
//
// v1 = SHOW-ALL (fail-open): токен клиента `su10-launcher` сейчас не несёт claim'ов `resource_access`
// (client-роли) и `groups`, поэтому для всех порталов возвращается true — витрина показывает все
// плитки. Гейтинг доступа выполняют сами порталы на своём OIDC-callback:
//   • EstiMat — по client-роли `access` (resource_access.estimat.roles);
//   • BillHub — по членству в группе `billhub-active`.
//
// Точная фильтрация плиток на стороне витрины появится отдельным шагом и потребует добавить в токен
// клиента `su10-launcher` мапперы `groups` + client-роли. До тех пор логику fail-open НЕ ужесточаем:
// если данных о ролях в токене нет — плитку не скрываем.
export function hasPortalAccess(user: User | null | undefined, portal: Portal): boolean {
  if (!portal.requiredRole) return true;
  const [client, role] = portal.requiredRole.split(':');
  const resourceAccess = (user?.profile as Record<string, unknown> | undefined)?.[
    'resource_access'
  ] as Record<string, { roles?: string[] }> | undefined;
  const roles = resourceAccess?.[client]?.roles;
  if (!roles) return true; // нет данных о ролях в токене — не скрываем (fail-open, см. выше)
  return roles.includes(role);
}
