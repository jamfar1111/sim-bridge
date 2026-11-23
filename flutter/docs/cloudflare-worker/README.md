# Cloudflare Worker deploy (WebRTC signalling)

Deploy needs Farhad's own free Cloudflare account (no card required).

```sh
cd cloudflare-worker
npx wrangler login
npx wrangler deploy
```

Then copy the deployed URL (e.g. `https://sim-bridge-signal.<you>.workers.dev`)
into the WebRTC settings in the app's Link tab.

TURN relay (optional, for symmetric NATs — 1,000 GB/month free):
Cloudflare dashboard → Realtime → TURN → create a key, then an API token
with `Calls:Edit`, then generate ICE servers and paste them into the
app's Link tab TURN section. Without them the transport still works
direct / via STUN, just without relay.
