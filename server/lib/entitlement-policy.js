export function isProtectedManualLifetimeEntitlement(entitlement) {
  return entitlement?.source === "manual"
    && entitlement?.status === "active"
    && entitlement?.tier === "foundingLifetime";
}

export function isAllowedClientEntitlementSource(source) {
  return source === "app_store";
}
