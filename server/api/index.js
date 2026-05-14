import express from "express";

import v1_inventory_router from "./v1/inventory.js";
import v1_recipe_router from "./v1/recipe.js";
import v1_grocery_router from "./v1/grocery.js";
import v1_notifications_router from "./v1/notifications.js";
import v1_provider_connect_router from "./v1/provider-connect.js";
import v1_instacart_router from "./v1/instacart.js";
import v1_feedback_router from "./v1/feedback.js";
import v1_entitlements_router from "./v1/entitlements.js";
import v1_recurring_router from "./v1/recurring.js";
import v1_account_router from "./v1/account.js";
import v1_push_tokens_router from "./v1/push-tokens.js";
import v1_app_store_notifications_router from "./v1/app-store-notifications.js";
import v1_bootstrap_router from "./v1/bootstrap.js";
import v1_prep_router from "./v1/prep.js";

const app_router = express.Router();
const v1_routers = [v1_inventory_router, v1_recipe_router, v1_grocery_router, v1_notifications_router, v1_provider_connect_router, v1_instacart_router, v1_feedback_router, v1_entitlements_router, v1_bootstrap_router, v1_prep_router, v1_recurring_router, v1_account_router, v1_push_tokens_router, v1_app_store_notifications_router];

v1_routers.forEach((router) => {
  app_router.use("/v1", router);
});

app_router.use("/v1", (req, res) => {
  res.json({ message: "Hello from API v1" });
});
export default app_router;
