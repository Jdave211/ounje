import { FOOD_ITEMS } from "./constants";
import { RECIPE } from "./constants";
import { GENERATED_RECIPES } from "./constants";

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

export const GENERATE_RECIPES_PROMPT = `
  You will be provided with a list of only food items, and you generate exactly 1 exciting recipe (output in json) using these ingredients, along with a few extra easily accessible ingredients if needed. The recipes will be returned in the following format:
  ${JSON.stringify(GENERATED_RECIPES)}
  Assume I have no knowledge of cooking and I am beginner, so fill the instructions with as much detail as possible.
	Make sure that the instructions for the recipe are clear and detailed enough to be followed by someone who is not a professional chef
	Do not beat around the bush with extra text or formalities, just return the recipes in the format above and that is all.
  Make sure that the recipe covers at least 75% of recipes i have on hand. If it have multiple food items, do not try to use all of them for one recipe.
  If you are prompted further to return a different recipe, do not return the same recipe as before. Try to use another mix of ingredients to create a different recipe.
  Here are the food items:
`;
