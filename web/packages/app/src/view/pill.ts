import type { HtmlBuilder } from "foldkit/html";
import { Message } from "../message.ts";

export const pill = (h: HtmlBuilder<Message>, text: string, tone: string) => h.span([h.Class(`pill ${tone}`)], [text]);
