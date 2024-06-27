import { FOOD_ITEMS } from "./constants";
import { RECIPE } from "./constants";
import { GPT_RECIPE } from "./constants";
import { GENERATED_NAMES } from "./constants";

const categories = [
  "juices",
  "dairy",
  "condiments",
  "vegetables",
  "spreads",
  "protein",
  "grains",
  "fruits",
  "frozen",
  "canned",
  "spices",
  "sauces",
  "snacks",
  "desserts",
];

let inventory = ["fridge", "freezer", "pantry", "counter", "table", "storage"];

export const FOOD_ITEMS_PROMPT = `
  List all the food items in each of these food images/inventories in an array.
  Within each inventory, break the food items in similar food categories that describe the food items (e.g. fruits, condiments, drinks, meats, etc.).
  Be as specific as possible for each individual item even if they are in a category and include the quantity of each item such that we have enough
  information to create a recipe for a meal.
  The quantity should only be a number indicating the amount of the named item in the inventory.
  Categorize them into this format:
  { "inventory_name": { "category_name": {name: text, quantity: number} }}.
  Similiar to this: ${JSON.stringify(FOOD_ITEMS)}.
  Follow the types in the format strictly. numbers should only be numbers and text should only be text.
  The image name should represent the environment where the food items are found.
  The categories should be very similar and have broad definitions of the food items like these ones: ${categories.join(", ")}
  The inventories should be very similar to these ones: ${inventory.join(", ")}.
  For duplicate inventories you can increment the name of the inventory by adding a number to the end of the name.
  `;

// todo: add description, nutritional information (array),

export const RECIPES_PROMPT = `Take in this recipe from my database and the ingredients I already have in my inventory and come up with an identical recipe I can make mainly with the ingredients I have.
  The recipe should be as close to the original as possible and should be a recipe that I can make with the ingredients I have.
  You are allowed to include 1 or 2 extra ingredients that I might not have in my inventory but should be common enough that I can find them in a local store.
  Assume I have no knowledge of cooking and I am beginner, so fill the instructions with as much detail as possible.
	Make sure that the instructions for the recipe are clear and detailed enough to be followed by someone who is not a professional chef.
	if there might be specific instructions for items included in their packaging, give them the instructions for doing that activity along with pointing them to the package in case the instructions differ
  Return the recipe in the same format as the original recipe. Similar to this: ${JSON.stringify(RECIPE)}.`;

export const ADD_FOOD_PROMPT =
  "Imagine you are a food inspector whose sole responsibility is to assess food items for safety and ensure they are fit for human consumption. If you encounter any unsafe items, remove them from the list and return the revised list. If all items are safe, return the list as is. For example, given the list [rice, gunpowder, eggs], you should return [rice, eggs].";

export const GENERATE_RECIPE_NAMES_PROMPT = `
  You will be provided with a list of food items, and your task is to generate the names of 5 vastly different recipes that can be made using these ingredients, along with a few extra easily accessible ingredients if needed.
  Carefully select ingredients to ensure they fit well together based on common culinary practices and nutritional compositions, and distribute them across various recipes instead of combining all in one. Exclude any ingredients that do not fit well together. I do not want to see some disguting stuff like beef and apple stir fry or anything of the likes.
  Ensure each recipe name reflects a dish that is both appetizing and commonly enjoyed by people. The recipe names should represent diverse culinary styles to ensure variety and creativity, with no single recipe combining all provided ingredients excessively.
  Include one authentic Nigerian recipe that reflects traditional Nigerian cuisine, such as "Amala and Egusi" or "Ofada Rice and Ayamase."
  Return the results in this JSON format: ${JSON.stringify(GENERATED_NAMES)}.

  Here are my food items:
`;

export const GENERATE_RECIPES_PROMPT = `
  You will be provided with a list of food items, and your task is to generate exactly 1 exciting recipe in JSON format using these ingredients, along with a few extra easily accessible ingredients if needed.
  Carefully analyze each ingredient to determine if they go well together based on common culinary practices and nutritional compositions. Exclude any ingredient that doesn't fit well with the others. Only generate recipes with ingredients you are sure go well together. Ensure the recipe is both appetizing and nutritionally balanced, suitable for someone with no knowledge of cooking. The instructions should be easy to follow, step-by-step.
  At least 50% of the ingredients should come from the list I will provide.

  The format of the recipe should strictly adhere to the following structure:
  ${JSON.stringify(GPT_RECIPE)}

  Use this structure strictly, ensuring numbers are only used for quantities, times, and servings, while text is used for names and instructions. Avoid adding extra text or formalities.

  If prompted further to return a different recipe, do not repeat any previous recipes. Use another mix of ingredients to create a recipe from a different part of the world.

  Here are the food items:
  `;

export const GENERATE_RECIPE_DETAILS_PROMPT = `
  You will be provided with the name of a recipe. Your task is to generate the full recipe details in JSON format using the provided ingredients, along with a few extra easily accessible ingredients if needed.
  Carefully analyze the recipe name to determine the best ingredients and steps based on common culinary practices and nutritional compositions. Ensure the recipe is both appetizing and nutritionally balanced, suitable for someone with no knowledge of cooking. The instructions should be easy to follow, step-by-step.
  The format of the recipe should strictly adhere to the following structure:
  ${JSON.stringify(GPT_RECIPE)}

  Use this structure strictly, ensuring numbers are only used for quantities, times, and servings, while text is used for names and instructions. Avoid adding extra text or formalities.

  Here is the recipe name:
`;
