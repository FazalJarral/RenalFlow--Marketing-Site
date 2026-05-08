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
    if (!env.RENALFLOW_API_URL || !env.RENALFLOW_MARKETING_SYNC_SECRET) {
      return json({ error: "RenalFlow checkout validation is not configured" }, { status: 500 });
    }

    const body = await request.json().catch(() => ({}));
    const response = await fetch(`${env.RENALFLOW_API_URL.replace(/\/$/, "")}/api/billing/validate-plan-change`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-renalflow-sync-secret": env.RENALFLOW_MARKETING_SYNC_SECRET
      },
      body: JSON.stringify({
        center_id: body.center_id,
        target_plan_slug: body.target_plan_slug,
        billing_interval: body.billing_interval || "monthly",
        action: body.action || "marketing_checkout"
      })
    });

    const payload = await response.json().catch(() => ({}));
    return json(payload, { status: response.status });
  } catch (error) {
    return json({ error: error.message || "Checkout validation failed" }, { status: 500 });
  }
}

export async function onRequest() {
  return json({ error: "Method not allowed" }, { status: 405, headers: { Allow: "POST" } });
}
