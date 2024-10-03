import express from "express";

import v1_inventory_router from "./v1/inventory.js";
import v1_recipe_router from "./v1/recipe.js";

const app_router = express.Router();
const v1_routers = [v1_inventory_router, v1_recipe_router];

v1_routers.forEach((router) => {
  app_router.use("/v1", router);
});

app_router.use("/v1", (req, res) => {
  res.json({ message: "Hello from API v1" });
});
export default app_router;
