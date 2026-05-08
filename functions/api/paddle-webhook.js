function json(body, init = {}) {
  return new Response(JSON.stringify(body), {
    ...init,
    headers: {
      "Content-Type": "application/json",
      ...(init.headers || {})
    }
  });
}

export async function onRequestPost({ request, env }) {
  try {
    assertEnv(env);
    const rawBody = await request.text();
    const signature = request.headers.get("paddle-signature");
    await verifyPaddleSignature(signature, rawBody, env.PADDLE_WEBHOOK_SECRET);

    const response = await fetch(`${env.RENALFLOW_API_URL.replace(/\/$/, "")}/api/billing-webhook`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "paddle-signature": signature,
        "x-renalflow-sync-secret": env.RENALFLOW_MARKETING_SYNC_SECRET || ""
      },
      body: rawBody
    });

    const payload = await response.json().catch(() => ({}));
    return json(payload, { status: response.status });
  } catch (error) {
    const status = error.statusCode || 500;
    console.error("Paddle webhook forward failed", {
      status,
      message: error.message
    });
    return json({ error: status >= 500 ? "Webhook processing failed" : error.message }, { status });
  }
}

export async function onRequest() {
  return json({ error: "Method not allowed" }, { status: 405, headers: { Allow: "POST" } });
}

function assertEnv(env) {
  const required = ["PADDLE_WEBHOOK_SECRET", "RENALFLOW_API_URL"];
  for (const name of required) {
    if (!env[name]) {
      const error = new Error(`Missing ${name}`);
      error.statusCode = 500;
      throw error;
    }
  }
}

async function verifyPaddleSignature(signatureHeader, rawBody, secret) {
  if (!signatureHeader) {
    const error = new Error("Missing Paddle signature");
    error.statusCode = 401;
    throw error;
  }

  const parts = Object.fromEntries(
    String(signatureHeader)
      .split(";")
      .map((part) => part.split("="))
      .filter(([key, value]) => key && value)
      .map(([key, value]) => [key.trim(), value.trim()])
  );

  const timestamp = parts.ts;
  const signatures = String(parts.h1 || "").split(",");
  if (!timestamp || signatures.length === 0 || !signatures[0]) {
    const error = new Error("Malformed Paddle signature");
    error.statusCode = 401;
    throw error;
  }

  const ageMs = Math.abs(Date.now() - Number(timestamp) * 1000);
  if (!Number.isFinite(ageMs) || ageMs > 5 * 60 * 1000) {
    const error = new Error("Expired Paddle signature");
    error.statusCode = 401;
    throw error;
  }

  const expected = await hmacSha256Hex(secret, `${timestamp}:${rawBody}`);
  const matched = signatures.some((signature) => timingSafeEqualHex(signature, expected));

  if (!matched) {
    const error = new Error("Invalid Paddle signature");
    error.statusCode = 401;
    throw error;
  }
}

async function hmacSha256Hex(secret, payload) {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(payload));
  return [...new Uint8Array(signature)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function timingSafeEqualHex(left, right) {
  const normalizedLeft = String(left || "").toLowerCase();
  const normalizedRight = String(right || "").toLowerCase();
  if (!/^[0-9a-f]+$/.test(normalizedLeft) || normalizedLeft.length !== normalizedRight.length) return false;

  let diff = 0;
  for (let index = 0; index < normalizedRight.length; index += 1) {
    diff |= normalizedLeft.charCodeAt(index) ^ normalizedRight.charCodeAt(index);
  }
  return diff === 0;
}
