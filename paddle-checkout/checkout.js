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
const checkoutContext = {
  transactionId: params.get("_ptxn") || "",
  plan: (params.get("plan") || "").toLowerCase(),
  activationRequestId: params.get("activation_request_id") || "",
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
let paddleConfig = null;

function showMessage(message, isWarning = false) {
  checkoutMessage.textContent = message;
  checkoutMessage.classList.toggle("checkout-warning", isWarning);
}

function renderPlan(plan) {
  const copy = planCopy[plan];
  if (!copy) return;

  selectedName.textContent = copy.name;
  selectedDetails.textContent = copy.details;
  selectedPrice.textContent = copy.price;
  checkoutTitle.textContent = `${copy.name} checkout`;
  checkoutCopy.textContent = `Complete the ${copy.name} subscription for RenalFlow. ${copy.details}`;
}

function validateQuery() {
  if (!planCopy[checkoutContext.plan]) {
    throw new Error("Choose a valid RenalFlow plan from the desktop app or pricing page.");
  }

  if (!checkoutContext.activationRequestId || checkoutContext.activationRequestId.length > 160) {
    throw new Error("Missing activation_request_id. Open checkout from the RenalFlow desktop activation flow.");
  }

  if (checkoutContext.transactionId && !/^txn_[a-z0-9]+$/i.test(checkoutContext.transactionId)) {
    throw new Error("The Paddle transaction passed to checkout is not valid.");
  }

  if (checkoutContext.email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(checkoutContext.email)) {
    throw new Error("The email passed to checkout is not valid.");
  }
}

async function loadCheckoutConfig() {
  const response = await fetch(`/api/paddle-config?plan=${encodeURIComponent(checkoutContext.plan)}`, {
    headers: { Accept: "application/json" }
  });
  const body = await response.json().catch(() => ({}));

  if (!response.ok) {
    throw new Error(body.error || "Checkout configuration could not be loaded.");
  }

  return body;
}

function initializePaddle() {
  if (paddleReady) return true;
  if (!window.Paddle || !paddleConfig?.clientToken || !paddleConfig?.priceId) return false;

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

  if (checkoutContext.successUrl) settings.successUrl = checkoutContext.successUrl;

  if (checkoutContext.transactionId) {
    return {
      settings,
      transactionId: checkoutContext.transactionId
    };
  }

  const payload = {
    settings,
    items: [
      {
        priceId: paddleConfig.priceId,
        quantity: 1
      }
    ],
    customData: {
      activation_request_id: checkoutContext.activationRequestId,
      product: "renalflow-desktop",
      plan: checkoutContext.plan
    }
  };

  if (checkoutContext.email) {
    payload.customer = { email: checkoutContext.email };
  }

  return payload;
}

function openCheckout() {
  if (!initializePaddle()) {
    showMessage("Paddle Checkout could not load. Refresh the page or try again from RenalFlow desktop.", true);
    return;
  }

  // The browser only starts Paddle Checkout. License provisioning is intentionally deferred
  // until the backend receives and verifies Paddle's signed payment webhook.
  showMessage("Paddle Checkout is loaded below. Complete payment, then return to RenalFlow.");
  checkoutButton.textContent = "Reload checkout";
  window.Paddle.Checkout.open(checkoutPayload());
}

async function start() {
  try {
    validateQuery();
    renderPlan(checkoutContext.plan);
    paddleConfig = await loadCheckoutConfig();
    openCheckout();
  } catch (error) {
    checkoutTitle.textContent = "Checkout cannot start";
    checkoutCopy.textContent = error.message;
    selectedName.textContent = "Invalid request";
    selectedDetails.textContent = "RenalFlow could not validate this checkout link.";
    selectedPrice.textContent = "--";
    showMessage(error.message, true);
  }
}

checkoutButton.addEventListener("click", openCheckout);
start();
