export function isUuid(value: unknown): value is string {
  return (
    typeof value === 'string' &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
  );
}

export function isLatitude(v: unknown): v is number {
  return typeof v === 'number' && v >= -90 && v <= 90;
}

export function isLongitude(v: unknown): v is number {
  return typeof v === 'number' && v >= -180 && v <= 180;
}

export function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

export function requireFields<T extends object>(
  body: unknown,
  fields: (keyof T)[]
): T | string {
  if (typeof body !== 'object' || body === null) return 'Request body must be a JSON object';
  for (const field of fields) {
    if (!(field as string in body)) return `Missing required field: ${String(field)}`;
  }
  return body as T;
}
