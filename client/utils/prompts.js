export const FOOD_ITEMS_PROMPT = `
  List all the food items in each of these food inventories in an array.
  Within each inventory, break the food items in similar food categories that describe the food items (e.g. fruits, condiments, drinks, meats, etc.).
  Be as specific as possible for each individual item even if they are in a category and include the quantity of each item such that we have enough
  information to create a recipe for a meal.
  The quantity should only be a number indicating the amount of the named item in the inventory.
  Categorize them into this format:
  { "inventory_name": { "category_name": {name: text, quantity: number} }}.
  Follow the types in the format strictly. numbers should only be numbers and text should only be text.
  The image name should represent the environment where the food items are found.`;

export const RECIPES_PROMPT = `Create multiple recipes for meals using the food items that the user provides using this format in a single array of json object.
	Assume the user has no knowledge of cooking and is a beginner, so fill the instructions with as much detail as possible.
	Make sure that the instructions for the recipe are clear and detailed enough to be followed by someone who is not a professional chef.
	if there might be specific instructions for items included in their packaging, give them the instructions for doing that activity along with pointing them to the package in case the instructions differ.
	Include an image prompt to use to generate a good image of the finished recipe in image_prompt.
	Generate a unique id for each recipe, if the recipe has been generated before, reuse the same id.
	Do not hold back because you are conserned about the content not fitting into a single response, you can spread the data accross multiple responses, just make sure that there is no seperation between the data that is that the data is continuous between the responses.
	format is as follows:
	{ "name": text, unique_id: text(uuid 34 chars) , image_prompt: text, duration: number, servings: number, "ingredients": {name: text, quantity: number, displayed_text: text, already_have: bool}, "instructions": [text] }
	Put the appropriate commas, between each object in the array and between each key value pair in the object.`;
