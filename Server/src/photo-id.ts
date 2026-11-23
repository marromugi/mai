import { lowercaseUuid } from "./uuid";

/** A photo ID in the lowercase text form: the UUID the app made for the photo. */
export type PhotoId = string & { readonly brand: unique symbol };

export function parsePhotoId(text: string): PhotoId | undefined {
  const lowered = text.toLowerCase();
  return isPhotoId(lowered) ? lowered : undefined;
}

function isPhotoId(text: string): text is PhotoId {
  return lowercaseUuid.test(text);
}

/** A photo is kept as two parts, each sealed apart on the device: the photo and its thumbnail. */
export type PhotoPart = "photo" | "thumbnail";

export function parsePhotoPart(text: string): PhotoPart | undefined {
  return text === "photo" || text === "thumbnail" ? text : undefined;
}
