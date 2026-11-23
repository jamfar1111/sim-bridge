// Sim Bridge — WebRTC signalling server (finding 7).
//
// A Cloudflare Worker + Durable Object that lets the two phones
// exchange WebRTC offers / answers / ICE candidates when they are
// far apart. The Dart side talks to it through `HttpSignalling`
// (`lib/src/link/webrtc_transport.dart`):
//
//   POST /signal  {"room": "<room-id>", "message": {...}}  → {"ok": true}
//   GET  /signal?room=<room-id>&since=<cursor>            → {"messages": [...], "cursor": <n>}
//
// The room id is the SHA-256 of the Android phone's static public
// key (`webrtcRoomId`), so both phones derive the same room from
// the pairing — no account, no registration. Messages are small
// (SDP + ICE candidates) and expire after 10 minutes; the room
// holds at most 100. Nothing else is stored, and the server never
// sees call audio or SMS — only signalling.
//
// Message authentication (finding N6): the room id is public (it is
// printed in the pairing QR code), so anyone who sees the QR could
// POST fake offers into the room. The phones therefore HMAC every
// message with SHA-256 of the pairing token (`SignallingAuth` in the
// Dart code) and drop messages whose HMAC does not verify. The
// Worker CANNOT verify the HMAC — it never learns the token, and
// giving it the token would defeat the purpose — so it only
// rate-limits the room (60 POSTs per minute per room; 429 beyond)
// to keep a stranger from flooding it. The HMAC still protects the
// handshake itself: a forged offer cannot pass verification, so it
// cannot break the real one.
//
// Deploy (needs a free Cloudflare account, no card):
//   1. `npm install -g wrangler` (or `npx wrangler`)
//   2. Save this file as `worker.js` and the `wrangler.toml` below
//      next to it, then `wrangler login && wrangler deploy`.
//   3. Copy the deployed URL (e.g.
//      `https://sim-bridge-signal.<you>.workers.dev`) into
//      the WebRTC settings in the app's Link tab (finding N3).
//
// TURN credentials (relay for symmetric NATs — the 1,000 GB/month
// free Cloudflare TURN allowance):
//   1. Cloudflare dashboard → Realtime → TURN → create a key.
//   2. Create an API token with the `Calls:Edit` permission.
//   3. `curl -X POST "https://rtc.live.cloudflare.com/v1/turn/keys/<key-id>/credentials/generate-ice-servers" -H "Authorization: Bearer <token>"`
//      → the response `iceServers` give a `username` + `credential`
//      (valid 24 h — regenerate daily, or fetch them in the app at
//      startup from the Link tab's TURN section). Without them the
//      transport still works direct / via STUN, just without relay.
//
// wrangler.toml:
//   name = "sim-bridge-signal"
//   main = "worker.js"
//   compatibility_date = "2026-11-23"
//   [durable_objects]
//   bindings = [{ name = "SIGNAL_ROOM", class_name = "SignalRoom" }]
//   [[migrations]]
//   tag = "v1"
//   new_sqlite_classes = ["SignalRoom"]

export class SignalRoom {
  constructor(state) {
    this.state = state;
    this.messages = []; // {id, at, message}
    this.nextId = 1;
    // Rate limiting (finding N6): POST timestamps in the last
    // minute, per room. The Worker cannot verify the HMAC, so this
    // is the only flood protection it can offer.
    this.postedAt = [];
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (request.method === "POST" && url.pathname === "/signal") {
      const now = Date.now();
      this.postedAt = this.postedAt.filter((t) => now - t < 60 * 1000);
      if (this.postedAt.length >= 60) {
        return json({ error: "rate limited" }, 429);
      }
      const body = await request.json();
      if (typeof body?.message !== "object" || body.message === null) {
        return json({ error: "bad message" }, 400);
      }
      this.postedAt.push(now);
      this.messages.push({
        id: this.nextId++,
        at: now,
        message: body.message,
      });
      if (this.messages.length > 100) {
        this.messages.splice(0, this.messages.length - 100);
      }
      return json({ ok: true });
    }
    if (request.method === "GET" && url.pathname === "/signal") {
      const since = Number(url.searchParams.get("since") || "0");
      const now = Date.now();
      this.messages = this.messages.filter((m) => now - m.at < 10 * 60 * 1000);
      const fresh = this.messages.filter((m) => m.id > since);
      return json({
        messages: fresh.map((m) => m.message),
        cursor: this.messages.length ? this.messages.at(-1).id : since,
      });
    }
    return json({ error: "not found" }, 404);
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== "/signal") {
      return json({ error: "not found" }, 404);
    }
    const room =
      request.method === "GET"
        ? url.searchParams.get("room") || ""
        : (await request.clone().json().catch(() => ({}))).room || "";
    if (!/^[0-9a-f]{64}$/.test(room)) {
      return json({ error: "bad room" }, 400);
    }
    const id = env.SIGNAL_ROOM.idFromName(room);
    const stub = env.SIGNAL_ROOM.get(id);
    return stub.fetch(request);
  },
};

function json(value, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: {
      "content-type": "application/json",
      "access-control-allow-origin": "*",
    },
  });
}
