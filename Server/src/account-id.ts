/**
 * An account ID in the lowercase text form: the UUID the app made, which is also its purchases'
 * `appAccountToken`.
 */
export type AccountId = string & { readonly brand: unique symbol };

export function parseAccountId(text: string): AccountId | undefined {
  const lowered = text.toLowerCase();
  return isAccountId(lowered) ? lowered : undefined;
}

function isAccountId(text: string): text is AccountId {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(text);
}
