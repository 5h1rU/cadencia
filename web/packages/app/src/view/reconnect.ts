import type { HtmlBuilder } from "foldkit/html";
import { Message } from "../message.ts";

export const reconnectLink = (h: HtmlBuilder<Message>, text: string) => h.a([h.Href("/auth/intervals/start")], [text]);
