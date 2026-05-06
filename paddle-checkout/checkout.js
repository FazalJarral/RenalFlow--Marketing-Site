const paddleConfig = {
  // Replace with the client-side token from your Paddle account.
  // Example shape: clientToken: "test_..." or "live_..."
  clientToken: "PADDLE_CLIENT_SIDE_TOKEN",
  environment: "sandbox",
  prices: {
    starter: "pri_01kqjg3ak7r2n1nsqm94m10v73",
    growth: "pri_01kqjg435a0dn8qa8qke04y53c",
    pro: "pri_01kqjg4jfh9bhm6qbnbwnw6vpn"
  }
};

const planCopy = {
  starter: {
    name: "Starter",
    price: "$39/month",
    details: "3 active users, 100 active patients, 2 GB storage."
  },
  growth: {
    name: "Growth",
    price: "$99/month",
    details: "10 active users, 500 active patients, 10 GB storage."
  },
  pro: {
    name: "Pro",
    price: "$249/month",
    details: "25 active users, 1500 active patients, 50 GB storage."
  }
};

const params = new URLSearchParams(window.location.search);
let selectedPlan = planCopy[params.get("plan")] ? params.get("plan") : "growth";
const signupContext = {
  centerId: params.get("center_id") || params.get("centerId") || "",
  email: params.get("email") || "",
  successUrl: params.get("success_url") || "",
  cancelUrl: params.get("cancel_url") || ""
};

const selectedName = document.querySelector("#selected-plan-name");
const selectedDetails = document.querySelector("#selected-plan-details");
const selectedPrice = document.querySelector("#selected-plan-price");
const checkoutButton = document.querySelector("#open-checkout");
const checkoutMessage = document.querySelector("#checkout-message");
const checkoutTitle = document.querySelector("#checkout-card-title");
const checkoutCopy = document.querySelector("#checkout-card-copy");
let paddleReady = false;

function updatePlan(plan) {
  selectedPlan = plan;
  const copy = planCopy[plan];
  selectedName.textContent = copy.name;
  selectedDetails.textContent = copy.details;
  selectedPrice.textContent = copy.price;
  checkoutTitle.textContent = `${copy.name} checkout`;
  checkoutCopy.textContent = `Complete the ${copy.name} subscription for RenalFlow. ${copy.details}`;
}

function hasRealPaddleConfig() {
  return (
    paddleConfig.clientToken &&
    !paddleConfig.clientToken.includes("PLACEHOLDER") &&
    !paddleConfig.clientToken.includes("PADDLE_") &&
    paddleConfig.prices[selectedPlan] &&
    !paddleConfig.prices[selectedPlan].includes("PADDLE_PRICE_ID")
  );
}

function initializePaddle() {
  if (paddleReady) return true;
  if (!window.Paddle || !hasRealPaddleConfig()) return false;
  if (paddleConfig.environment === "sandbox") {
    window.Paddle.Environment.set("sandbox");
  }
  window.Paddle.Initialize({
    token: paddleConfig.clientToken
  });
  paddleReady = true;
  return true;
}

function checkoutPayload() {
  const settings = {
    displayMode: "inline",
    frameTarget: "paddle-checkout-frame",
    frameInitialHeight: 560,
    frameStyle: "width:100%; min-width:312px; background-color: transparent; border: none;"
  };

  if (signupContext.successUrl) settings.successUrl = signupContext.successUrl;

  const payload = {
    settings,
    items: [
      {
        priceId: paddleConfig.prices[selectedPlan],
        quantity: 1
      }
    ],
    customData: {
      plan_slug: selectedPlan,
      source: "renalflow_desktop_signup"
    }
  };

  if (signupContext.centerId) payload.customData.center_id = signupContext.centerId;
  if (signupContext.email) payload.customer = { email: signupContext.email };
  return payload;
}

function openCheckout() {
  if (!initializePaddle()) {
    checkoutMessage.innerHTML =
      "Checkout could not load. Confirm Paddle values in <code>paddle-checkout/checkout.js</code> and check your connection.";
    checkoutMessage.classList.add("checkout-warning");
    return;
  }

  checkoutMessage.textContent = "Paddle Checkout is loaded below. Complete payment, then return to RenalFlow.";
  checkoutMessage.classList.remove("checkout-warning");
  checkoutButton.textContent = "Reload checkout";
  window.Paddle.Checkout.open(checkoutPayload());
}

checkoutButton.addEventListener("click", openCheckout);

updatePlan(selectedPlan);
openCheckout();
