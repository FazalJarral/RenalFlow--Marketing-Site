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

export async function onRequestGet({ request, env }) {
  const url = new URL(request.url);
  const plan = String(url.searchParams.get("plan") || "").toLowerCase();
  const priceId = ALLOWED_PLANS[plan];

  if (!priceId) {
    return json({ error: "Invalid RenalFlow plan" }, { status: 400 });
  }

  if (!env.PADDLE_CLIENT_TOKEN) {
    console.error("Paddle checkout config missing PADDLE_CLIENT_TOKEN");
    return json({ error: "Checkout is not configured" }, { status: 500 });
  }

  const environment = env.PADDLE_ENVIRONMENT || "sandbox";
  const expectedTokenPrefix = environment === "sandbox" ? "test_" : "live_";
  if (!env.PADDLE_CLIENT_TOKEN.startsWith(expectedTokenPrefix)) {
    console.error("Paddle checkout config has an invalid client-side token prefix", {
      environment,
      expectedTokenPrefix
    });
    return json({ error: "Checkout is not configured" }, { status: 500 });
  }

  return json({
    plan,
    priceId,
    clientToken: env.PADDLE_CLIENT_TOKEN,
    environment
  });
}

export async function onRequest() {
  return json({ error: "Method not allowed" }, { status: 405, headers: { Allow: "GET" } });
}
