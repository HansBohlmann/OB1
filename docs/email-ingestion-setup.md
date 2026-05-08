# Email Ingestion Setup

> Pipe inbound email into Open Brain via the `ingest-email` Edge Function.

## What this gives you

- Forward (or BCC) any email to `capture@yourdomain` and it lands in your brain as a typed, embedded, entity-linked thought — same pipeline as a Slack `#capture` post.
- Reply chains and signatures are stripped automatically.
- Sender allowlist (default: `hans.bohlmann@gmail.com`) prevents random inbound mail from polluting the brain.
- Per editorial-policy.md R2, R5: empty/auto-reply/unsubscribe-footer emails route to `type=fragment` with empty arrays — they don't inflate into observations.

## Architecture

```
inbound email → MX record → upstream router → POST → ingest-email Edge Function → thoughts table
```

The Edge Function is provider-agnostic. Any service that can POST a normalised JSON payload works. The recommended path is **Cloudflare Email Routing + Email Workers** because it's free for any domain you've added to Cloudflare and the Worker code is short.

## Recommended path: Cloudflare Email Routing

### Prerequisites
- A custom domain managed at Cloudflare (Hans, you've got `clarity88.ai` and similar — any domain you control works).
- Cloudflare Email Routing enabled on that domain (Cloudflare dashboard → Email → Email Routing → Enable).
- The MX records Cloudflare provides set as your authoritative MX (Cloudflare adds them automatically once Email Routing is enabled).

### Step 1 — Create a Cloudflare Email Worker

In the Cloudflare dashboard: **Workers & Pages → Create Worker**. Name it `email-to-openbrain`. Paste this code:

```js
export default {
  async email(message, env) {
    const ALLOW = (env.OPEN_BRAIN_INGEST_KEY ?? "").trim();
    if (!ALLOW) {
      console.error("missing OPEN_BRAIN_INGEST_KEY env binding");
      return;
    }

    // Read the message bodies. message.text is the plain-text body;
    // message.raw is the full RFC822 stream (used as fallback).
    let bodyText = "";
    try {
      bodyText = await new Response(message.text).text();
    } catch (_) {
      bodyText = "";
    }

    let bodyHtml = "";
    try {
      bodyHtml = await new Response(message.html ?? "").text();
    } catch (_) {
      bodyHtml = "";
    }

    const payload = {
      from: message.from,
      from_name: message.headers.get("from")?.replace(/<.*>/, "").trim() ?? null,
      subject: message.headers.get("subject") ?? "",
      body_text: bodyText,
      body_html: bodyHtml,
      message_id: message.headers.get("message-id") ?? null,
      received_at: new Date().toISOString(),
      to: message.to,
    };

    const url = `https://hngyvkxfclblzcobxatf.supabase.co/functions/v1/ingest-email?key=${encodeURIComponent(ALLOW)}`;
    const r = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });

    if (!r.ok) {
      console.error(`ingest-email returned ${r.status}: ${await r.text().catch(() => "")}`);
      // Don't throw — we don't want Cloudflare to bounce the email.
      return;
    }
    const json = await r.json().catch(() => ({}));
    console.log(`captured ${json.thought_id} as ${json.type}`);
  },
};
```

### Step 2 — Bind the access key

In the Worker's settings: **Variables and Secrets → Add → Encrypted**:
- Name: `OPEN_BRAIN_INGEST_KEY`
- Value: `open-brain-hans-2026` (or whatever you set `EMAIL_INGEST_ACCESS_KEY` to in Supabase)

Save and deploy the Worker.

### Step 3 — Create an Email Routing rule

In the Cloudflare dashboard: **Email → Email Routing → Routing rules → Create address**.

- Custom address: `capture@yourdomain` (e.g. `capture@clarity88.ai`)
- Action: **Send to a Worker**
- Worker: `email-to-openbrain` (the one you just created)

Save.

### Step 4 — Test before relying on it

Send a test email from your allowlisted address:

```
To:      capture@yourdomain
Subject: Test capture from email
Body:    This is a test of the email ingestion pipeline.
```

Within ~30 seconds, query your brain via MCP or SQL to confirm:

```sql
SELECT id, content, metadata, created_at
FROM thoughts
WHERE metadata->>'source' = 'email'
ORDER BY created_at DESC
LIMIT 3;
```

You should see your test capture with `metadata.type` set, `metadata.email.from` populated, and the body cleanly extracted (no headers, no signature).

## Direct curl test (before configuring DNS)

You can verify the Edge Function works without any DNS changes:

```bash
curl -X POST 'https://hngyvkxfclblzcobxatf.supabase.co/functions/v1/ingest-email?key=open-brain-hans-2026' \
  -H 'Content-Type: application/json' \
  -d '{
    "from": "hans.bohlmann@gmail.com",
    "subject": "Test capture",
    "body_text": "Quick test — board paper due Friday. Need to chase Lyle for risk register input.",
    "message_id": "<test-001@example.com>",
    "received_at": "2026-05-08T12:00:00Z"
  }'
```

Expected response:
```json
{
  "ok": true,
  "thought_id": "...",
  "type": "task",
  "topics": ["board paper","risk register"],
  "confidence": "high"
}
```

If you get `403 sender not allowed`, your address isn't on the allowlist. Set the `EMAIL_INGEST_ALLOWLIST` env var in Supabase (comma-separated), or use the default (`hans.bohlmann@gmail.com`).

## Allowlist management

The allowlist exists to prevent random inbound mail (or spoofed sender addresses) from being captured. Default is `hans.bohlmann@gmail.com`.

To add more addresses (work email, family member's address you trust, etc.):

```bash
cd "/Users/hansbohlmann/Documents/Claude/Projects/Open Brain /OB1"
supabase secrets set --project-ref hngyvkxfclblzcobxatf \
  EMAIL_INGEST_ALLOWLIST="hans.bohlmann@gmail.com,hans@clarity88.ai,other@example.com"
```

(No code redeploy needed — the function reads the env var per request.)

## Alternative paths (not recommended for v1, but documented)

- **ImprovMX** — free tier forwards email to a webhook. Their JSON shape is similar to Cloudflare's; would need a thin adapter on top of the Cloudflare-shaped payload above.
- **Mailgun Inbound Parse** — production-grade, $35/mo for any meaningful volume.
- **Postmark Inbound** — clean JSON payload, $15/mo.

The Cloudflare path is free and adequate for personal-brain volumes (Hans receives < 1k emails/day). Move to a paid service only if you hit Cloudflare's rate limits, which you won't.

## What to do if email ingestion goes weird

- **Auto-replies and listserv noise inflating into the brain:** add the offending sender to a deny pattern. The current allowlist is exact-match; if you find yourself manually deleting list-mail captures, propose an `EMAIL_INGEST_DENYLIST` env var as the next iteration.
- **Reply chains not stripped cleanly:** the function uses common patterns (Gmail "On X, Y wrote", Outlook "Original Message", Apple "Begin forwarded message"). If your client uses something different, share an example and we'll widen the regex.
- **HTML-only emails losing structure:** the current `htmlToText` is conservative — strips tags, decodes common entities. Tables and lists become flowing text. If a specific email type loses meaning, point at it and we'll add a richer parser.

## Related files

- Edge Function: `supabase/functions/ingest-email/index.ts`
- Editorial policy reference: `docs/editorial-policy.md` (R2, R5, R7)
- Slack capture (parallel pipeline): `supabase/functions/ingest-thought/index.ts`
