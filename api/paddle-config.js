const ALLOWED_PLANS = {
  starter: "pri_01kqjg3ak7r2n1nsqm94m10v73",
  growth: "pri_01kqjg435a0dn8qa8qke04y53c",
  pro: "pri_01kqjg4jfh9bhm6qbnbwnw6vpn"
};

module.exports = async function handler(req, res) {
  if (req.method !== "GET") {
    res.setHeader("Allow", "GET");
    return res.status(405).json({ error: "Method not allowed" });
  }

  const plan = String(req.query.plan || "").toLowerCase();
  const priceId = ALLOWED_PLANS[plan];

  if (!priceId) {
    return res.status(400).json({ error: "Invalid RenalFlow plan" });
  }

  if (!process.env.PADDLE_CLIENT_TOKEN) {
    console.error("Paddle checkout config missing PADDLE_CLIENT_TOKEN");
    return res.status(500).json({ error: "Checkout is not configured" });
  }

  return res.status(200).json({
    plan,
    priceId,
    clientToken: process.env.PADDLE_CLIENT_TOKEN,
    environment: process.env.PADDLE_ENVIRONMENT || "sandbox"
  });
};
