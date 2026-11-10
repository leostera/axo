import { getContentType, isJidBroadcast, isJidNewsletter, jidNormalizedUser, normalizeMessageContent, proto, type WAMessage } from "baileys";
import type { MessageRow } from "./store";

/**
 * What one message WhatsApp sent the device means for the cache: a message to keep, a change to
 * one already kept (an edit, a delete for everyone), or nothing (a reaction, a key exchange, a
 * status update).
 */
export type MessageChange =
  | { kind: "message"; row: MessageRow }
  | { kind: "edit"; chatId: string; id: string; text: string }
  | { kind: "delete"; chatId: string; id: string };

/** Chats the device never keeps: status updates, broadcast lists and channels. */
export function ignoredChat(jid: string | null | undefined): boolean {
  return !jid || isJidBroadcast(jid) === true || isJidNewsletter(jid) === true;
}

/**
 * Reads one message. `canonical` turns a LID into the phone number JID it stands for, when
 * known, so a person's messages land in one chat whichever ID WhatsApp used.
 */
export function messageChange(message: WAMessage, canonical: (jid: string) => string = (jid) => jid): MessageChange | null {
  const key = message.key;
  const remote = key?.remoteJid;
  if (!key?.id || ignoredChat(remote)) return null;
  // WhatsApp may name a person by their LID and give the number beside it.
  const chatId = canonical(jidNormalizedUser(preferNumber(remote!, key.remoteJidAlt)));
  const content = normalizeMessageContent(message.message);
  if (!content) return null;
  const type = getContentType(content);
  if (!type) return null;
  if (type === "protocolMessage") {
    const protocol = content.protocolMessage!;
    const target = protocol.key?.id;
    if (!target) return null;
    if (protocol.type === proto.Message.ProtocolMessage.Type.REVOKE) return { kind: "delete", chatId, id: target };
    if (protocol.type === proto.Message.ProtocolMessage.Type.MESSAGE_EDIT && protocol.editedMessage) {
      const edited = textOf(normalizeMessageContent(protocol.editedMessage));
      return edited === null ? null : { kind: "edit", chatId, id: target, text: edited };
    }
    return null;
  }
  if (type === "editedMessage") {
    const inner = content.editedMessage?.message?.protocolMessage;
    const target = inner?.key?.id;
    const edited = inner?.editedMessage ? textOf(normalizeMessageContent(inner.editedMessage)) : null;
    return target && edited !== null ? { kind: "edit", chatId, id: target, text: edited } : null;
  }
  const text = textOf(content);
  if (text === null) return null;
  const fromMe = key.fromMe === true;
  const participant = key.participant ? canonical(jidNormalizedUser(preferNumber(key.participant, key.participantAlt))) : null;
  const sender = fromMe ? null : participant ?? (chatId.endsWith("@g.us") ? null : chatId);
  return {
    kind: "message",
    row: {
      chatId,
      id: key.id,
      fromMe,
      sender,
      pushName: fromMe ? null : message.pushName ?? null,
      at: seconds(message.messageTimestamp),
      type: type.replace(/Message$/, ""),
      text,
      quotedId: contextOf(content)?.stanzaId ?? null,
      deleted: false,
    },
  };
}

/** A message's words as the person would read them; media are named by kind, with their caption. Null for what is not a message. */
export function textOf(content: proto.IMessage | undefined): string | null {
  if (!content) return null;
  const caption = (kind: string, text: string | null | undefined) => (text ? `[${kind}] ${text}` : `[${kind}]`);
  if (content.conversation) return content.conversation;
  if (content.extendedTextMessage?.text) return content.extendedTextMessage.text;
  if (content.imageMessage) return caption("photo", content.imageMessage.caption);
  if (content.videoMessage) return caption(content.videoMessage.gifPlayback ? "GIF" : "video", content.videoMessage.caption);
  if (content.audioMessage) return content.audioMessage.ptt ? "[voice message]" : "[audio]";
  if (content.documentMessage) return caption("document", [content.documentMessage.fileName, content.documentMessage.caption].filter(Boolean).join(": "));
  if (content.documentWithCaptionMessage?.message?.documentMessage) {
    const document = content.documentWithCaptionMessage.message.documentMessage;
    return caption("document", [document.fileName, document.caption].filter(Boolean).join(": "));
  }
  if (content.stickerMessage) return "[sticker]";
  if (content.contactMessage) return caption("contact", content.contactMessage.displayName);
  if (content.contactsArrayMessage) return caption("contacts", content.contactsArrayMessage.displayName);
  if (content.locationMessage) return caption("location", [content.locationMessage.name, content.locationMessage.address].filter(Boolean).join(", ") || coordinates(content.locationMessage));
  if (content.liveLocationMessage) return "[live location]";
  const poll = content.pollCreationMessage ?? content.pollCreationMessageV2 ?? content.pollCreationMessageV3;
  if (poll) return caption("poll", [poll.name, ...(poll.options ?? []).map((option) => `- ${option.optionName ?? ""}`)].join("\n"));
  if (content.eventMessage) return caption("event", content.eventMessage.name);
  if (content.buttonsResponseMessage?.selectedDisplayText) return content.buttonsResponseMessage.selectedDisplayText;
  if (content.listResponseMessage?.title) return content.listResponseMessage.title;
  if (content.templateButtonReplyMessage?.selectedDisplayText) return content.templateButtonReplyMessage.selectedDisplayText;
  return null;
}

function coordinates(location: proto.Message.ILocationMessage): string {
  return location.degreesLatitude != null && location.degreesLongitude != null ? `${location.degreesLatitude}, ${location.degreesLongitude}` : "";
}

function contextOf(content: proto.IMessage): proto.IContextInfo | null | undefined {
  return content.extendedTextMessage?.contextInfo ?? content.imageMessage?.contextInfo ?? content.videoMessage?.contextInfo
    ?? content.audioMessage?.contextInfo ?? content.documentMessage?.contextInfo ?? content.stickerMessage?.contextInfo;
}

/** A person's JID: the phone number's, when WhatsApp gave both it and a LID. */
export function preferNumber(jid: string, alt: string | null | undefined): string {
  return jid.endsWith("@lid") && alt?.endsWith("@s.whatsapp.net") ? alt : jid;
}

/** WhatsApp's timestamps, which come as numbers or protobuf Longs, in seconds. */
export function seconds(value: number | { toNumber(): number } | null | undefined): number {
  if (value === null || value === undefined) return 0;
  return typeof value === "number" ? value : value.toNumber();
}

/** `447700900123:12@s.whatsapp.net` → `+447700900123`: the account's name. */
export function accountOf(jid: string): string {
  const user = jid.split("@")[0]!.split(":")[0]!;
  return `+${user}`;
}
