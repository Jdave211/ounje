import express from "express";
import {
  InventoryModel,
  addInventoryImages,
  deleteInventoryImages,
  getInventoryData,
  removeInventoryItems,
  addInventoryItems,
} from "../../models/Inventory.js";

const inventory_router = express.Router();

inventory_router.delete("/images/", async (req, res) => {
  const { user_id, images } = req.body;
  console.log("deleting all images", { user_id });
  await deleteInventoryImages(user_id);
  res.json({ message: "Deleting images" });
});

// add a new item to the inventory
inventory_router.post("/images/", async (req, res) => {
  const { user_id, images_and_food_items } = req.body;
  console.log("adding an image", { user_id, images_and_food_items });

  await addInventoryImages(user_id, images_and_food_items);
  res.json({ message: "Item added to inventory" });
});

// need supabase server authentication
inventory_router.get("/", async (req, res) => {
  const { user_id } = req.query;
  console.log("fetching inventory", { user_id });

  const inventory = await getInventoryData(user_id);

  res.json(inventory);
});

inventory_router.get("/history", async (req, res) => {
  const { user_id } = req.query;
  console.log("fetching inventory history", { user_id });

  const inventory_history = await InventoryModel.findOne({ user_id })
    .select("history")
    .sort({ date: -1 });

  res.json(inventory_history);
});

// add manually added items
inventory_router.post("/items", async (req, res) => {
  const { user_id, items } = req.body;
  console.log("adding items", { user_id, items });

  await addInventoryItems(user_id, items);

  res.status(200).send("Item added to inventory");
});

inventory_router.delete("/items", async (req, res) => {
  const { user_id, items } = req.body;
  console.log("deleting items", { user_id, items });

  await removeInventoryItems(user_id, items);
  res.status(200).send("Item removed from inventory");
});

const prefixed_inventory_router = express.Router();
prefixed_inventory_router.use("/inventory", inventory_router);

export default prefixed_inventory_router;
