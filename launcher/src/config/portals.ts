import type { User } from 'oidc-client-ts';

// Портал контура su10. requiredRole — опциональный гейт: client-роль вида "<clientId>:<role>",
// например "estimat:access". Если задан и в токене есть resource_access.<client>.roles — плитка
// фильтруется; если инфы о ролях в токене нет — портал показывается (доступ проверит сам портал).
export interface Portal {
  id: string;
  name: string;
  description: string;
  url: string;
  icon: string; // эмодзи-заглушка; заменить на SVG/лого
  requiredRole?: string;
}

export const PORTALS: Portal[] = [
  {
    id: 'estimat',
    name: 'EstiMat',
    description: 'Сметный портал — сметы, ВОР, справочники',
    url: 'https://estimat.su10.ru',
    icon: '📐',
    requiredRole: 'estimat:access',
  },
  {
    id: 'billhub',
    name: 'BillHub',
    description: 'Портал платежей и договоров',
    url: 'https://rp.su10.ru',
    icon: '🧾',
    requiredRole: 'billhub:access',
  },
];

// Проверка доступа к порталу по client-роли из access token (resource_access.<client>.roles).
// Если requiredRole не задан или ролей в профиле нет — считаем доступным (гейт на стороне портала).
export function hasPortalAccess(user: User | null | undefined, portal: Portal): boolean {
  if (!portal.requiredRole) return true;
  const [client, role] = portal.requiredRole.split(':');
  const resourceAccess = (user?.profile as Record<string, unknown> | undefined)?.[
    'resource_access'
  ] as Record<string, { roles?: string[] }> | undefined;
  const roles = resourceAccess?.[client]?.roles;
  if (!roles) return true; // нет данных о ролях в токене — не скрываем
  return roles.includes(role);
}
