const ALLOWED_PLANS = {
  starter: "pri_01kqjg3ak7r2n1nsqm94m10v73",
  growth: "pri_01kqjg435a0dn8qa8qke04y53c",
  pro: "pri_01kqjg4jfh9bhm6qbnbwnw6vpn"
};

const ACTIVE_TRANSACTION_EVENTS = new Set([
  "transaction.completed",
  "transaction.paid",
  "subscription.created",
  "subscription.activated",
  "subscription.updated"
]);

const FAILED_EVENTS = new Set(["transaction.payment_failed", "subscription.payment_failed"]);

const SUBSCRIPTION_STATUS = {
  active: "active",
  trialing: "active",
  past_due: "past_due",
  paused: "inactive",
  canceled: "cancelled",
  cancelled: "cancelled",
  deleted: "cancelled"
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

    const event = JSON.parse(rawBody);
    const eventType = event.event_type;
    const data = event.data || {};

    console.log("Received Paddle webhook", {
      eventId: event.event_id,
      eventType,
      dataId: data.id
    });

    if (isPaidEvent(eventType, data) && data.custom_data?.activation_request_id) {
      await provisionPaidLicense(env, eventType, data);
    } else if (isStatusEvent(eventType, data)) {
      await updateLicenseStatus(env, eventType, data);
    } else if (isPaidEvent(eventType, data)) {
      await updateLicenseStatus(env, eventType, { ...data, status: data.status || "active" });
    } else {
      console.log("Ignoring Paddle webhook event", { eventType, dataId: data.id });
    }

    return json({ received: true });
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

  const signedPayload = `${timestamp}:${rawBody}`;
  const expected = await hmacSha256Hex(secret, signedPayload);
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

function isPaidEvent(eventType, data) {
  if (!ACTIVE_TRANSACTION_EVENTS.has(eventType)) return false;
  if (eventType.startsWith("transaction.")) return data.status === "paid" || data.status === "completed";
  return normalizeLicenseStatus(data.status) === "active";
}

function isStatusEvent(eventType, data) {
  return (
    FAILED_EVENTS.has(eventType) ||
    eventType.startsWith("subscription.") ||
    ["subscription.canceled", "subscription.cancelled", "subscription.paused", "subscription.past_due"].includes(eventType)
  );
}

async function provisionPaidLicense(env, eventType, data) {
  const customData = data.custom_data || {};
  const activationRequestId = customData.activation_request_id;
  const plan = String(customData.plan || "").toLowerCase();

  validateActivationPayload(activationRequestId, plan, data);

  const existingLicense = await getLicenseByActivationRequestId(env, activationRequestId);
  const email = data.customer?.email || data.customer_email || existingLicense?.email || null;
  const licenseKey = existingLicense?.license_key || generateLicenseKey();
  const status = normalizeLicenseStatus(data.status) || "active";

  const license = {
    license_key: licenseKey,
    activation_request_id: activationRequestId,
    email,
    paddle_customer_id: data.customer_id || data.customer?.id || existingLicense?.paddle_customer_id || null,
    paddle_subscription_id: data.subscription_id || data.subscription?.id || existingLicense?.paddle_subscription_id || null,
    paddle_transaction_id: eventType.startsWith("transaction.") ? data.id : existingLicense?.paddle_transaction_id || null,
    plan,
    status,
    updated_at: new Date().toISOString()
  };

  await upsertActivationRequest(env, {
    activation_request_id: activationRequestId,
    email,
    selected_plan: plan,
    status: "paid"
  });
  await upsertLicense(env, license);

  console.log("Provisioned RenalFlow license from Paddle webhook", {
    activationRequestId,
    plan,
    licenseStatus: status,
    paddleCustomerId: license.paddle_customer_id,
    paddleSubscriptionId: license.paddle_subscription_id,
    paddleTransactionId: license.paddle_transaction_id
  });
}

async function updateLicenseStatus(env, eventType, data) {
  const customData = data.custom_data || {};
  const activationRequestId = customData.activation_request_id;
  const subscriptionId = data.subscription_id || data.id;
  const transactionId = eventType.startsWith("transaction.") ? data.id : data.transaction_id || null;
  const status = FAILED_EVENTS.has(eventType) ? "past_due" : normalizeLicenseStatus(data.status);

  if (!status) {
    console.log("No mapped license status for Paddle event", { eventType, paddleStatus: data.status });
    return;
  }

  const existingLicense = activationRequestId
    ? await getLicenseByActivationRequestId(env, activationRequestId)
    : await getLicenseBySubscriptionId(env, subscriptionId);

  if (!existingLicense) {
    console.log("No license found for Paddle status update", { eventType, activationRequestId, subscriptionId });
    return;
  }

  await patchLicense(env, existingLicense.id, {
    status,
    paddle_subscription_id: subscriptionId || existingLicense.paddle_subscription_id,
    paddle_transaction_id: transactionId || existingLicense.paddle_transaction_id,
    updated_at: new Date().toISOString()
  });

  const activationStatus = status === "cancelled" ? "expired" : status === "past_due" ? "failed" : "paid";
  await patchActivationRequest(env, existingLicense.activation_request_id, {
    status: activationStatus,
    updated_at: new Date().toISOString()
  });

  console.log("Updated RenalFlow license status from Paddle webhook", {
    activationRequestId: existingLicense.activation_request_id,
    eventType,
    status,
    subscriptionId
  });
}

function validateActivationPayload(activationRequestId, plan, data) {
  if (!activationRequestId || typeof activationRequestId !== "string" || activationRequestId.length > 160) {
    const error = new Error("Missing activation_request_id in Paddle custom_data");
    error.statusCode = 400;
    throw error;
  }

  const expectedPriceId = ALLOWED_PLANS[plan];
  if (!expectedPriceId) {
    const error = new Error("Invalid plan in Paddle custom_data");
    error.statusCode = 400;
    throw error;
  }

  const observedPriceIds = extractPriceIds(data);
  if (observedPriceIds.length > 0 && !observedPriceIds.includes(expectedPriceId)) {
    const error = new Error("Paddle price does not match selected plan");
    error.statusCode = 400;
    throw error;
  }
}

function extractPriceIds(data) {
  const ids = [];
  for (const item of data.items || []) {
    const priceId = item.price?.id || item.price_id;
    if (priceId) ids.push(priceId);
  }
  return ids;
}

function normalizeLicenseStatus(status) {
  return SUBSCRIPTION_STATUS[String(status || "").toLowerCase()] || null;
}

function generateLicenseKey() {
  const bytes = new Uint8Array(24);
  crypto.getRandomValues(bytes);
  const token = [...bytes].map((byte) => byte.toString(36).padStart(2, "0")).join("").toUpperCase();
  return `RF-${token.slice(0, 8)}-${token.slice(8, 16)}-${token.slice(16, 24)}`;
}

async function getLicenseByActivationRequestId(env, activationRequestId) {
  const rows = await supabaseFetch(env, `/licenses?activation_request_id=eq.${encodeURIComponent(activationRequestId)}&select=*`, {
    method: "GET"
  });
  return rows[0] || null;
}

async function getLicenseBySubscriptionId(env, subscriptionId) {
  if (!subscriptionId) return null;
  const rows = await supabaseFetch(env, `/licenses?paddle_subscription_id=eq.${encodeURIComponent(subscriptionId)}&select=*`, {
    method: "GET"
  });
  return rows[0] || null;
}

async function upsertLicense(env, license) {
  return supabaseFetch(env, "/licenses?on_conflict=activation_request_id", {
    method: "POST",
    headers: { Prefer: "resolution=merge-duplicates,return=representation" },
    body: JSON.stringify([license])
  });
}

async function patchLicense(env, id, patch) {
  return supabaseFetch(env, `/licenses?id=eq.${encodeURIComponent(id)}`, {
    method: "PATCH",
    headers: { Prefer: "return=minimal" },
    body: JSON.stringify(patch)
  });
}

async function upsertActivationRequest(env, record) {
  return supabaseFetch(env, "/activation_requests?on_conflict=activation_request_id", {
    method: "POST",
    headers: { Prefer: "resolution=merge-duplicates,return=minimal" },
    body: JSON.stringify([
      {
        ...record,
        updated_at: new Date().toISOString()
      }
    ])
  });
}

async function patchActivationRequest(env, activationRequestId, patch) {
  return supabaseFetch(env, `/activation_requests?activation_request_id=eq.${encodeURIComponent(activationRequestId)}`, {
    method: "PATCH",
    headers: { Prefer: "return=minimal" },
    body: JSON.stringify(patch)
  });
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
