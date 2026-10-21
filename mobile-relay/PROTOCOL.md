# Relay protocol v1

One deployment serves one public origin and one configured Mac key. Public static files and all mobile API requests share this origin. The relay has no database, session store or task queue. The Mac remains responsible for API routes, device pairing, authorization, `requestId` idempotency, `bootID` validation, workspace history and CLI execution.

## Mac connection

The Mac opens `wss://<public-domain>/host` with **no Origin header**. Browser WebSocket clients send Origin and are rejected. The phone event upgrade described below is separate; other upgrade paths are rejected. The HTTP Host must exactly match `PUBLIC_ORIGIN.host` (DNS case-insensitive); forwarding headers cannot override it.

Relay → Mac, immediately after upgrade:

```json
{"type":"challenge","nonce":"<32 random bytes, standard padded base64>","protocol":1}
```

The challenge expires after 10 seconds and is usable for one authentication attempt. The Mac signs the decoded **raw 32 nonce bytes**, with no text prefix, JSON serialization, hashing step or Base64 wrapper, using Ed25519.

Mac → relay:

```json
{"type":"authenticate","publicKey":"<raw Ed25519 32-byte public key, base64>","signature":"<64-byte Ed25519 signature, base64>"}
```

The relay checks the public key against `THEALL_MAC_PUBLIC_KEY` using constant-time equality, builds SPKI using hex prefix `302a300506032b6570032100`, and verifies the signature. Noncanonical Base64, wrong lengths, wrong key/signature, expired or repeated authentication, binary messages, invalid JSON and invalid message types are rejected. At most four unverified WebSocket connections are allowed.

Relay → Mac on success:

```json
{"type":"ready","protocol":1}
```

A newly authenticated Mac replaces the old connection. Existing requests owned by the old connection fail with 503; they are not transferred to the new host. Heartbeat ping/pong runs every 30 seconds; a connection that misses the next heartbeat is terminated. The Mac client should answer standard WebSocket pings and reconnect with a fresh handshake after disconnection. There is no persistent reconnect token.

## HTTP forwarding

Browser requests are forwarded only after Host, Origin, fetch-site, method, size and concurrency checks. The relay never interprets chat JSON or rewrites an attacker-supplied Origin into the trusted origin.

Relay → Mac:

```json
{
  "type":"request",
  "id":"<relay-generated UUID>",
  "method":"POST",
  "target":"/api/chats/<id>/send",
  "headers":{
    "host":"theall.example.com",
    "origin":"https://theall.example.com",
    "cookie":"<opaque device cookie>",
    "content-type":"application/json",
    "content-length":"<decoded body byte length>",
    "x-theall-client":"1"
  },
  "body":"<original HTTP request body, base64>"
}
```

`id` is transport correlation only, distinct from the app's mutation `requestId`. `target` is the original relative request URL, including its query string. Header names are lowercase, values are strings. Hop-by-hop headers, fields named by Connection, Forwarded, Via, and X-Forwarded-* are removed. `host` is set to the configured host **only after the incoming host was validated**. Content-Length is recomputed. Empty GET bodies use `"body":""`.

Mac → relay:

```json
{
  "type":"response",
  "id":"<same relay UUID>",
  "status":200,
  "headers":{"content-type":"application/json","set-cookie":"<optional opaque cookie>"},
  "body":"<HTTP response body bytes, base64>"
}
```

Response status must be 200–599. Headers are case-insensitive and string-valued; `set-cookie` alone may also be an array of strings, preserving multiple cookies. The relay strips hop-by-hop and Access-Control-* headers, computes Content-Length, and forces `Cache-Control: no-store`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`. Mac-provided CSP is preserved. Invalid response headers/body/status terminate the host connection and fail its pending requests. Late responses for expired or disconnected requests are ignored. Body bytes may be binary (for example PNG icons); Base64 is canonical padded RFC 4648.

No `cancel` or streaming response message exists in protocol v1. A browser disconnect releases its transport slot; the Mac may finish the task and its late response is discarded. The relay never retries a request. Mutation uncertainty and retry decisions remain with the existing client and Mac idempotency ledger.

## HTTP admission

- Only GET and POST. HEAD/OPTIONS/other methods receive 405; no CORS responses are emitted.
- Host must match the configured public origin, with exactly one Host header.
- Any provided Origin must equal `PUBLIC_ORIGIN` exactly. `Sec-Fetch-Site: cross-site` is rejected. GET navigation may omit Origin.
- POST additionally requires Origin, `X-TheAll-Client: 1`, and `Content-Type: application/json` (optional charset accepted).
- Request targets must be relative paths beginning with `/`, not `//`; fragments and targets over 4 KiB are rejected.
- GET bodies and `Expect: 100-continue` are unsupported.
- No authenticated Mac: immediate 503 JSON `{ "error": "Mac offline" }`.

| Limit | Value |
| --- | --- |
| Request body | 512 KiB |
| Request/response headers | 16 KiB |
| Decoded response body | 16 MiB |
| WebSocket message | 24 MiB, compression disabled |
| Pending requests, including body reads | 32 |
| Unverified host connections | 4 |
| Read body deadline | 15 seconds |
| Mac response deadline after forwarding | 50 seconds |
| Host authentication deadline | 10 seconds |
| Heartbeat | 30 seconds |
| Queued host output admission threshold | 4 MiB |
| Node HTTP connection cap | 128 |

Error responses use `{ "error": "..." }` with the same no-store/security headers. Body too large: 413. Headers too large: 431. Pending capacity: 503. Slow body: 408. Mac response deadline: 504. Disconnect/replacement: 503. No request is queued for later delivery.

## Embedding in tests

```js
import { createRelay, parseConfig } from './server.mjs';
const relay = createRelay({
  origin: 'http://127.0.0.1:8080',
  publicKey: Buffer.from(publicKeyBase64, 'base64'),
  bind: '127.0.0.1',
  port: 8080
});
await relay.listen(); // Returns server.address().
await relay.close();
```

`createRelay(config, overrides)` optionally shortens individual exported `LIMITS` for integration tests; production CLI always uses fixed defaults. `parseConfig(environment)` validates environment-derived settings. Importing the module does not start a listener or print output.

## Phone event WebSocket extension

A paired phone opens `wss://<origin>/api/events` with its existing device cookie.
The exact Origin and Host are required; cross-site fetches and request bodies are
rejected. The relay does **not** authenticate the device cookie itself. It holds
the upgrade for at most 10 seconds and asks the authenticated Mac:

```json
{"type":"event_open","id":"<UUID>","method":"GET","target":"/api/events","headers":{"host":"theall.example.com","origin":"https://theall.example.com","cookie":"<opaque cookie>"}}
```

Headers use the same sanitization as HTTP forwarding. The Mac applies device,
entry/origin, and workspace permission checks before accepting:

```json
{"type":"event_opened","id":"<UUID>","status":101}
```

A 400–599 status rejects the upgrade with that HTTP status. Only after 101 does
the relay complete the phone handshake. Mac output follows on the same ordered
host connection; an initial hello may immediately follow `event_opened`:

```json
{"type":"event_data","id":"<UUID>","text":"{\"type\":\"changed\"}"}
```

The phone sees only the text value as a WebSocket text message. Phone text is
forwarded as `{"type":"event_input","id":"<UUID>","text":"..."}`. Either
side can send `{"type":"event_close","id":"<UUID>"}`; closure is idempotent,
and late messages for closed IDs are ignored. Device revocation is enforced by
the Mac closing its channel. Host disconnect/replacement closes every associated
phone channel; no subscriptions survive a new host handshake.

There are at most 16 pending/live phone channels, each message is at most 8 KiB,
compression and binary input are disabled, input is limited to 30 messages per
second, and queued phone output is bounded to 64 KiB. Standard WebSocket
ping/pong uses the 30-second heartbeat. A phone which misses a heartbeat is
terminated. Slow readers and excess input close only the affected channel.
Events signal changes; paginated history and all mutations remain HTTP with
the original idempotency and authorization rules. No API credentials enter this
protocol. A pre-extension relay rejects this path; clients may retain a polling
fallback until both Mac and relay have been updated.
