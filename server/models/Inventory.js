import { Binary, ObjectId } from "mongodb";
import mongoose, { Schema } from "mongoose";

const FoodItem = new Schema({
  name: String,
  spoonacular_data: Object,
});

const Inventory = new Schema({
  user_id: String,
  items_from_images: [
    {
      name: String,
      image: String,
      food_items: [Number],
    },
  ],
  manually_added_items: [
    {
      type: Number,
      required: true,
    },
  ],
  history: [
    {
      action: {
        type: String,
        enum: [
          "add_images",
          "remove_images",
          "add_items",
          "remove_items",
          "remove_image_items",
        ],
        required: true,
      },
      data: [
        {
          type: Object,
          required: true,
        },
      ],
      date: {
        type: Date,
        default: Date.now,
      },
    },
  ],
});

// History data can be

export const InventoryModel = mongoose.model("inventory", Inventory);

export const deleteInventoryImages = async (userId) => {
  const user_inventory_exists = await InventoryModel.exists({
    user_id: userId,
  });

  if (!user_inventory_exists) return await createNewInventory(userId);

  // delete the previous images
  const mongo_inventory_data = await InventoryModel.findOne({
    user_id: userId,
  });

  const options = { upsert: true, new: true, setDefaultsOnInsert: true };

  await InventoryModel.findOneAndUpdate(
    { user_id: userId },
    {
      $push: {
        history: {
          action: "remove_images",
          data: mongo_inventory_data.items_from_images,
        },
      },
      $set: {
        items_from_images: [],
      },
    },
    options
  );
};

export const addInventoryImages = async (userId, images) => {
  if (images.length === 0) return;

  const user_inventory_exists = await InventoryModel.exists({
    user_id: userId,
  });

  if (!user_inventory_exists) return await createNewInventory(userId);

  const options = { upsert: true, new: true, setDefaultsOnInsert: true };
  await InventoryModel.findOneAndUpdate(
    { user_id: userId },
    {
      $set: {
        items_from_images: images,
      },
      $push: {
        history: {
          action: "add_images",
          data: images,
        },
      },
    },
    options
  );
};

export const createNewInventory = async (userId) => {
  const new_inventory = new InventoryModel({
    user_id: userId,
    items_from_images: [],
    manually_added_items: [],
    history: [],
  });

  await new_inventory.save();
};

export const addInventoryItems = async (userId, items) => {
  if (items.length === 0) return;

  const user_inventory_exists = await InventoryModel.exists({
    user_id: userId,
  });

  if (!user_inventory_exists) return await createNewInventory(userId);

  console.log({ items });
  await InventoryModel.findOneAndUpdate(
    { user_id: userId },
    {
      $push: {
        manually_added_items: { $each: items },
        history: { action: "add_items", data: items },
      },
    }
  );
};

export const getInventoryData = async (userId) =>
  await InventoryModel.findOne({ user_id: userId }).select(
    "items_from_images manually_added_items"
  );

export const removeInventoryItems = async (userId, items) => {
  if (items.length === 0) return;

  const inventory = await getInventoryData(userId);
  const items_set = new Set(items);

  const manually_added_items = inventory.manually_added_items.filter((id) =>
    items_set.has(id)
  );

  const items_from_images = inventory.items_from_images.map((item) => ({
    image: item.image,
    food_items: item.food_items.filter((id) => items_set.has(id)),
  }));

  if (manually_added_items.length > 0) {
    await removeManuallyAddedItems(userId, manually_added_items);
  }

  if (items_from_images.length > 0) {
    await removeInventoryImageItems(userId, items_from_images);
  }
};

export const removeManuallyAddedItems = async (
  userId,
  manually_added_items
) => {
  if (manually_added_items.length === 0) return;
  const user_inventory_exists = await InventoryModel.exists({
    user_id: userId,
  });

  if (!user_inventory_exists) return;

  console.log({ manually_added_items });
  await InventoryModel.findOneAndUpdate(
    { user_id: userId },
    {
      $pull: { manually_added_items: { $in: manually_added_items } },
      $push: {
        history: { action: "remove_items", data: manually_added_items },
      },
    }
  );
};

export const removeInventoryImageItems = async (userId, items_from_images) => {
  if (items_from_images.length === 0) return;

  const user_inventory_exists = await InventoryModel.exists({
    user_id: userId,
  });

  if (!user_inventory_exists) return;

  const items_to_remove = items_from_images
    .map(({ food_items }) => food_items)
    .flat();

  if (items_to_remove.length === 0) return;

  console.log({ items_to_remove });

  await InventoryModel.findOneAndUpdate(
    { user_id: userId },
    {
      $pull: {
        "items_from_images.$[].food_items": {
          $in: items_to_remove,
        },
      },
      $push: {
        history: { action: "remove_image_items", data: items_from_images },
      },
    }
  );
};
