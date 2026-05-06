const crypto = require("crypto");

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

const FAILED_EVENTS = new Set([
  "transaction.payment_failed",
  "subscription.payment_failed"
]);

const SUBSCRIPTION_STATUS = {
  active: "active",
  trialing: "active",
  past_due: "past_due",
  paused: "inactive",
  canceled: "cancelled",
  cancelled: "cancelled",
  deleted: "cancelled"
};

module.exports = async function handler(req, res) {
  if (req.method !== "POST") {
    res.setHeader("Allow", "POST");
    return res.status(405).json({ error: "Method not allowed" });
  }

  try {
    assertEnv();
    const rawBody = await readRawBody(req);
    verifyPaddleSignature(req.headers["paddle-signature"], rawBody, process.env.PADDLE_WEBHOOK_SECRET);

    const event = JSON.parse(rawBody);
    const eventType = event.event_type;
    const data = event.data || {};

    console.log("Received Paddle webhook", {
      eventId: event.event_id,
      eventType,
      dataId: data.id
    });

    if (isPaidEvent(eventType, data) && data.custom_data?.activation_request_id) {
      await provisionPaidLicense(eventType, data);
    } else if (isStatusEvent(eventType, data)) {
      await updateLicenseStatus(eventType, data);
    } else if (isPaidEvent(eventType, data)) {
      await updateLicenseStatus(eventType, { ...data, status: data.status || "active" });
    } else {
      console.log("Ignoring Paddle webhook event", { eventType, dataId: data.id });
    }

    return res.status(200).json({ received: true });
  } catch (error) {
    const status = error.statusCode || 500;
    console.error("Paddle webhook failed", {
      status,
      message: error.message
    });
    return res.status(status).json({ error: status >= 500 ? "Webhook processing failed" : error.message });
  }
};

function assertEnv() {
  const required = ["PADDLE_WEBHOOK_SECRET", "SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY"];
  for (const name of required) {
    if (!process.env[name]) {
      const error = new Error(`Missing ${name}`);
      error.statusCode = 500;
      throw error;
    }
  }
}

function readRawBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function verifyPaddleSignature(signatureHeader, rawBody, secret) {
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
  if (!Number.isFinite(ageMs) || ageMs > 5 * 1000) {
    const error = new Error("Expired Paddle signature");
    error.statusCode = 401;
    throw error;
  }

  const signedPayload = `${timestamp}:${rawBody}`;
  const expected = crypto.createHmac("sha256", secret).update(signedPayload, "utf8").digest("hex");
  const expectedBuffer = Buffer.from(expected, "hex");

  const matched = signatures.some((signature) => {
    const signatureBuffer = Buffer.from(signature, "hex");
    return signatureBuffer.length === expectedBuffer.length && crypto.timingSafeEqual(signatureBuffer, expectedBuffer);
  });

  if (!matched) {
    const error = new Error("Invalid Paddle signature");
    error.statusCode = 401;
    throw error;
  }
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

async function provisionPaidLicense(eventType, data) {
  const customData = data.custom_data || {};
  const activationRequestId = customData.activation_request_id;
  const plan = String(customData.plan || "").toLowerCase();

  validateActivationPayload(activationRequestId, plan, data);

  const existingLicense = await getLicenseByActivationRequestId(activationRequestId);
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

  await upsertActivationRequest({
    activation_request_id: activationRequestId,
    email,
    selected_plan: plan,
    status: "paid"
  });
  await upsertLicense(license);

  console.log("Provisioned RenalFlow license from Paddle webhook", {
    activationRequestId,
    plan,
    licenseStatus: status,
    paddleCustomerId: license.paddle_customer_id,
    paddleSubscriptionId: license.paddle_subscription_id,
    paddleTransactionId: license.paddle_transaction_id
  });
}

async function updateLicenseStatus(eventType, data) {
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
    ? await getLicenseByActivationRequestId(activationRequestId)
    : await getLicenseBySubscriptionId(subscriptionId);

  if (!existingLicense) {
    console.log("No license found for Paddle status update", { eventType, activationRequestId, subscriptionId });
    return;
  }

  await patchLicense(existingLicense.id, {
    status,
    paddle_subscription_id: subscriptionId || existingLicense.paddle_subscription_id,
    paddle_transaction_id: transactionId || existingLicense.paddle_transaction_id,
    updated_at: new Date().toISOString()
  });

  const activationStatus = status === "cancelled" ? "expired" : status === "past_due" ? "failed" : "paid";
  await patchActivationRequest(existingLicense.activation_request_id, {
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
  const token = crypto.randomBytes(24).toString("base64url").toUpperCase();
  return `RF-${token.slice(0, 8)}-${token.slice(8, 16)}-${token.slice(16, 24)}`;
}

async function getLicenseByActivationRequestId(activationRequestId) {
  const rows = await supabaseFetch(
    `/licenses?activation_request_id=eq.${encodeURIComponent(activationRequestId)}&select=*`,
    { method: "GET" }
  );
  return rows[0] || null;
}

async function getLicenseBySubscriptionId(subscriptionId) {
  if (!subscriptionId) return null;
  const rows = await supabaseFetch(
    `/licenses?paddle_subscription_id=eq.${encodeURIComponent(subscriptionId)}&select=*`,
    { method: "GET" }
  );
  return rows[0] || null;
}

async function upsertLicense(license) {
  return supabaseFetch("/licenses?on_conflict=activation_request_id", {
    method: "POST",
    headers: { Prefer: "resolution=merge-duplicates,return=representation" },
    body: JSON.stringify([license])
  });
}

async function patchLicense(id, patch) {
  return supabaseFetch(`/licenses?id=eq.${encodeURIComponent(id)}`, {
    method: "PATCH",
    headers: { Prefer: "return=minimal" },
    body: JSON.stringify(patch)
  });
}

async function upsertActivationRequest(record) {
  return supabaseFetch("/activation_requests?on_conflict=activation_request_id", {
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

async function patchActivationRequest(activationRequestId, patch) {
  return supabaseFetch(`/activation_requests?activation_request_id=eq.${encodeURIComponent(activationRequestId)}`, {
    method: "PATCH",
    headers: { Prefer: "return=minimal" },
    body: JSON.stringify(patch)
  });
}

async function supabaseFetch(path, options) {
  const baseUrl = process.env.SUPABASE_URL.replace(/\/$/, "");
  const response = await fetch(`${baseUrl}/rest/v1${path}`, {
    ...options,
    headers: {
      apikey: process.env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${process.env.SUPABASE_SERVICE_ROLE_KEY}`,
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
