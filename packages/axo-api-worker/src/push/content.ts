import { z } from "zod";

const shortText = (limit: number) => z.string().min(1).max(limit * 2)
  .refine(value => value.trim().length > 0 && Array.from(value).length <= limit);
export const notificationContentSchema = z.strictObject({ title: shortText(60), message: shortText(240) });
// Retained content keeps its original bounds; new notifications are deliberately tweet-sized.
export const notifyInputSchema = notificationContentSchema.extend({
  title: shortText(48), message: shortText(140), idempotencyKey: z.uuid().optional(),
});
export type NotificationContent = z.infer<typeof notificationContentSchema>;
export const NOTIFICATION_CONFIRM_CATEGORY = "AXO_CONFIRM_V1";
export const NOTIFICATION_REVIEW_CATEGORY = "AXO_REVIEW_V1";

export async function questionDigest(message: string): Promise<string> {
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(message)));
  return Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("");
}

export function questionPreview(message: string): { body: string; complete: boolean } {
  const characters = Array.from(z.string().min(1).max(1000).parse(message));
  return characters.length <= 140 ? { body: message, complete: true }
    : { body: characters.slice(0, 139).join("") + "…", complete: false };
}
