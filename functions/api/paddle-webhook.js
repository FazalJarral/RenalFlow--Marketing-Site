const ALLOWED_PLANS = {
  starter: "pri_01kqjg3ak7r2n1nsqm94m10v73",
  growth: "pri_01kqjg435a0dn8qa8qke04y53c",
  pro: "pri_01kqjg4jfh9bhm6qbnbwnw6vpn"
};

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
    await verifyPaddleSignature(request.headers.get("paddle-signature"), rawBody, env.PADDLE_WEBHOOK_SECRET);

    const payload = JSON.parse(rawBody);
    const event = normalizePaddleEvent(payload);
    const eventRow = await storeBillingEvent(env, event);
    if (eventRow.duplicate && eventRow.status === "processed") {
      return json({ ok: true, duplicate: true });
    }

    const result = await applyBillingEvent(env, event);
    if (event.activationRequestId && result.applied) {
      await updateActivationRequest(env, event, result.status);
    }
    await markBillingEvent(env, eventRow.id, result.applied ? "processed" : "failed", result.reason || null);

    return json({ ok: true, applied: result.applied, reason: result.reason || null });
  } catch (error) {
    const status = error.statusCode || 500;
    console.error("Paddle webhook failed", {
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
  const required = ["PADDLE_WEBHOOK_SECRET", "SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY"];
  for (const name of required) {
    if (!env[name]) {
      const error = new Error(`Missing ${name}`);
      error.statusCode = 500;
      throw error;
    }
  }
}

function normalizePaddleEvent(payload) {
  const data = payload.data || {};
  const customData = data.custom_data || {};
  const priceId = findPriceId(data);
  const mappedPlanSlug = Object.entries(ALLOWED_PLANS).find(([, id]) => id === priceId)?.[0] || null;
  const eventType = payload.event_type || payload.type || "";
  const billingInterval = customData.billing_interval === "lifetime" ? "lifetime" : "monthly";

  return {
    provider: "paddle",
    providerEventId: payload.event_id || payload.id || null,
    eventType,
    centerId: customData.center_id || null,
    activationRequestId: customData.activation_request_id || null,
    planSlug: mappedPlanSlug || customData.plan_slug || customData.plan || null,
    billingInterval,
    priceId,
    unknownPriceId: Boolean(priceId && !mappedPlanSlug),
    customerId: data.customer_id || null,
    subscriptionId: data.subscription_id || (eventType.startsWith("subscription.") ? data.id : null),
    transactionId: eventType.startsWith("transaction.") ? data.id : null,
    status: data.status || null,
    currentPeriodStart: data.current_billing_period?.starts_at || data.billing_period?.starts_at || null,
    currentPeriodEnd: data.current_billing_period?.ends_at || data.billing_period?.ends_at || null,
    payload
  };
}

function findPriceId(data) {
  for (const item of data.items || []) {
    const priceId = item.price?.id || item.price_id;
    if (priceId) return priceId;
  }
  return data.price_id || data.price?.id || null;
}

async function applyBillingEvent(env, event) {
  if (event.unknownPriceId) return { applied: false, reason: `Unknown Paddle price id: ${event.priceId}` };
  if ((!event.centerId || !event.planSlug) && event.subscriptionId) {
    const existing = await supabaseFetch(env, `/subscriptions?billing_subscription_id=eq.${encodeURIComponent(event.subscriptionId)}&select=center_id,plans(slug)&limit=1`, {
      method: "GET"
    });
    if (existing[0]) {
      event.centerId = event.centerId || existing[0].center_id;
      event.planSlug = event.planSlug || existing[0].plans?.slug;
    }
  }
  if (!event.centerId || !event.planSlug) return { applied: false, reason: "Missing center_id or plan_slug." };

  const plans = await supabaseFetch(env, `/plans?slug=eq.${encodeURIComponent(event.planSlug)}&select=id&limit=1`, {
    method: "GET"
  });
  const plan = plans[0];
  if (!plan) return { applied: false, reason: `Unknown plan slug: ${event.planSlug}` };

  const status = mapSubscriptionStatus(event);
  if (!status) return { applied: false, reason: `Unhandled Paddle event type: ${event.eventType}` };

  await supabaseFetch(env, "/subscriptions?on_conflict=center_id", {
    method: "POST",
    headers: { Prefer: "resolution=merge-duplicates,return=minimal" },
    body: JSON.stringify([{
      center_id: event.centerId,
      plan_id: plan.id,
      status,
      billing_provider: "paddle",
      billing_customer_id: event.customerId,
      billing_subscription_id: event.subscriptionId,
      lifetime_access: status === "lifetime",
      current_period_start: event.currentPeriodStart || new Date().toISOString(),
      current_period_end: status === "lifetime" ? null : event.currentPeriodEnd,
      updated_at: new Date().toISOString()
    }])
  });

  return { applied: true, status };
}

function mapSubscriptionStatus(event) {
  const providerStatus = String(event.status || "").toLowerCase();
  if (event.billingInterval === "lifetime" && event.eventType === "transaction.completed") return "lifetime";
  if (
    event.eventType === "transaction.completed" ||
    event.eventType === "transaction.paid" ||
    event.eventType === "subscription.created" ||
    event.eventType === "subscription.updated" ||
    event.eventType === "subscription.activated" ||
    providerStatus === "active"
  ) return "active";
  if (
    event.eventType === "subscription.past_due" ||
    event.eventType === "subscription.paused" ||
    event.eventType === "transaction.payment_failed" ||
    providerStatus === "past_due" ||
    providerStatus === "paused"
  ) return "past_due";
  if (
    event.eventType === "subscription.canceled" ||
    event.eventType === "subscription.cancelled" ||
    providerStatus === "canceled" ||
    providerStatus === "cancelled"
  ) return "cancelled";
  if (event.eventType.includes("refunded") || event.eventType.includes("chargeback")) return "cancelled";
  return null;
}

async function storeBillingEvent(env, event) {
  if (event.providerEventId) {
    const existing = await supabaseFetch(env, `/billing_events?provider=eq.paddle&provider_event_id=eq.${encodeURIComponent(event.providerEventId)}&select=id,status&limit=1`, {
      method: "GET"
    });
    if (existing[0]) return { id: existing[0].id, duplicate: true, status: existing[0].status };
  }

  const rows = await supabaseFetch(env, "/billing_events", {
    method: "POST",
    headers: { Prefer: "return=representation" },
    body: JSON.stringify([{
      center_id: event.centerId,
      provider: "paddle",
      event_type: event.eventType,
      provider_event_id: event.providerEventId,
      payload: event.payload,
      status: "received"
    }])
  });
  return { id: rows[0].id, duplicate: false, status: rows[0].status };
}

async function markBillingEvent(env, id, status, errorMessage) {
  await supabaseFetch(env, `/billing_events?id=eq.${encodeURIComponent(id)}`, {
    method: "PATCH",
    headers: { Prefer: "return=minimal" },
    body: JSON.stringify({
      status,
      error_message: errorMessage,
      processed_at: new Date().toISOString()
    })
  });
}

async function updateActivationRequest(env, event, status) {
  const activationStatus = status === "lifetime" ? "active" : status === "cancelled" ? "cancelled" : status === "past_due" ? "past_due" : "active";
  await supabaseFetch(env, `/license_activation_requests?id=eq.${encodeURIComponent(event.activationRequestId)}`, {
    method: "PATCH",
    headers: { Prefer: "return=minimal" },
    body: JSON.stringify({
      status: activationStatus,
      provider_transaction_id: event.transactionId,
      provider_subscription_id: event.subscriptionId,
      activated_at: activationStatus === "active" ? new Date().toISOString() : null,
      updated_at: new Date().toISOString()
    })
  });
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

async function supabaseFetch(env, path, options) {
  const baseUrl = env.SUPABASE_URL.replace(/\/$/, "");
  const response = await fetch(`${baseUrl}/rest/v1${path}`, {
    ...options,
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      "Content-Type": "application/json",
      ...(options.headers || {})
    }
  });

  if (!response.ok) {
    const text = await response.text();
    const error = new Error(`Supabase request failed: ${response.status} ${text.slice(0, 220)}`);
    error.statusCode = 500;
    throw error;
  }

  if (response.status === 204) return null;
  return response.json();
}
