// Used by test/smoke.sh. Live-editing probe: a Hocuspocus client connects like the browser does (through nginx and the
// backend's /collab proxy), syncs the doc, then sees an API edit arrive live.
import { HocuspocusProvider } from "@hocuspocus/provider";
import * as Y from "yjs";
import BaseWS from "ws";
const [origin, token, ws, docId] = process.argv.slice(2);
const h = { Authorization: `Bearer ${token}`, "X-Workspace-ID": ws, "Content-Type": "application/json" };
const t = await (await fetch(`${origin}/api/docs/${docId}/collab-ticket`, { method: "POST", headers: h })).json();
// Sends an Origin header, as a browser does.
class WebSocket extends BaseWS { constructor(u, p) { super(u, p, { origin }); } }
const doc = new Y.Doc();
let updates = 0; doc.on("update", () => updates++);
const synced = new Promise((res, rej) => {
  setTimeout(() => rej(new Error("no sync in 15s")), 15000);
  new HocuspocusProvider({ url: origin.replace(/^http/, "ws") + "/collab", WebSocketPolyfill: WebSocket, name: t.document, token: t.token, document: doc,
    onSynced: () => res(), onAuthenticationFailed: (e) => rej(new Error("auth failed " + JSON.stringify(e))) });
});
await synced;
console.log("SYNCED", t.document, "updates", updates);
const before = updates;
const d = await (await fetch(`${origin}/api/docs/${docId}`, { headers: h })).json();
const r = await fetch(`${origin}/api/docs/${docId}`, { method: "PATCH", headers: h, body: JSON.stringify({ content: "live edit", base_revision: d.revision }) });
console.log("PATCH", r.status);
for (let i = 0; i < 50 && updates === before; i++) await new Promise((r) => setTimeout(r, 200));
console.log(updates > before ? "LIVE_UPDATE_OK" : "NO_LIVE_UPDATE", updates - before);
process.exit(updates > before ? 0 : 1);
