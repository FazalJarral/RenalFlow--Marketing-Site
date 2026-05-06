const paddleConfig = {
  // Replace with the client-side token from your Paddle account.
  // Example shape: clientToken: "test_..." or "live_..."
  clientToken: "PADDLE_CLIENT_TOKEN_PLACEHOLDER",
  environment: "sandbox",
  prices: {
    starter: "PADDLE_PRICE_ID_STARTER_MONTHLY",
    growth: "PADDLE_PRICE_ID_GROWTH_MONTHLY",
    pro: "PADDLE_PRICE_ID_PRO_MONTHLY"
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

const planButtons = document.querySelectorAll(".checkout-plan");
const selectedName = document.querySelector("#selected-plan-name");
const selectedDetails = document.querySelector("#selected-plan-details");
const selectedPrice = document.querySelector("#selected-plan-price");
const checkoutButton = document.querySelector("#open-checkout");
const checkoutMessage = document.querySelector("#checkout-message");

function updatePlan(plan) {
  selectedPlan = plan;
  const copy = planCopy[plan];
  selectedName.textContent = copy.name;
  selectedDetails.textContent = copy.details;
  selectedPrice.textContent = copy.price;
  planButtons.forEach((button) => {
    button.classList.toggle("active", button.dataset.plan === plan);
  });
}

function hasRealPaddleConfig() {
  return (
    paddleConfig.clientToken &&
    !paddleConfig.clientToken.includes("PLACEHOLDER") &&
    paddleConfig.prices[selectedPlan] &&
    !paddleConfig.prices[selectedPlan].includes("PADDLE_PRICE_ID")
  );
}

function initializePaddle() {
  if (!window.Paddle || !hasRealPaddleConfig()) return false;
  if (paddleConfig.environment === "sandbox") {
    window.Paddle.Environment.set("sandbox");
  }
  window.Paddle.Initialize({
    token: paddleConfig.clientToken
  });
  return true;
}

planButtons.forEach((button) => {
  button.addEventListener("click", () => {
    updatePlan(button.dataset.plan);
  });
});

checkoutButton.addEventListener("click", () => {
  if (!initializePaddle()) {
    checkoutMessage.innerHTML =
      "Checkout is ready, but Paddle values still need to be added in <code>paddle-checkout/checkout.js</code>.";
    checkoutMessage.classList.add("checkout-warning");
    return;
  }

  window.Paddle.Checkout.open({
    items: [
      {
        priceId: paddleConfig.prices[selectedPlan],
        quantity: 1
      }
    ]
  });
});

updatePlan(selectedPlan);
