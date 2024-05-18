import axios from "axios";
import dotenv from "dotenv";
import fs from "fs";
import OpenAi from "openai";

dotenv.config();

let openai = new OpenAi({
  apiKey: process.env.OPENAI_API_KEY,
});

let food_items_response = await openai.chat.completions.create({
  model: "gpt-4o",
  messages: [
	{
	  role: "system",
	  content: `List all the food items in each of these food inventories in an array. 
		  Within each inventory, break the food items in similar food categories that describe the food items (e.g. fruits, condiments, drinks, meats, etc.).
		  Be as specific as possible for each individual item even if they are in a category and include the quantity of each item such that we have enough 
		  information to create a recipe for a meal. 
		  The quantity should only be a number indicating the amount of the named item in the inventory.
		  Categorize them into this format:
		  { "invenory_name": { "category_name": {name: text, quantity: number} }}.
		  The image name should represent the environment where the food items are found.`,
	},
	{
	  role: "user",
	  content: [
		{
		  image: fs.readFileSync("./assets/food/fridge.jpg", "base64"),
		},
		{
		  image: fs.readFileSync("./assets/food/food-cabinet.png", "base64"),
		},
	  ],
	},
  ],
});

const extract_json = (data) => {
	console.log("messages: ", data.choices.length);
	
  const content = data.choices.map((choice) => choice.message.content).join("");
  console.log({ content })
  const regex = /^```json([\s\S]*?)^```/gm;
  const matches = regex.exec(content);

  if (!matches) {
	console.log("Could not convert to json", content)
  };

  let json_text = matches?.[0].replace(/^```json\n|\n```$/g, "") || content; // Remove the code block markers
  let object = JSON.parse(json_text);

  return [object, json_text]; // Remove the code block markers
};

const [food_items, food_items_text] = extract_json(food_items_response);
console.log({ food_items }); // Output: '

const len = fs.readdirSync("./runs").length + 1;

let dir_path = `./runs/run-${len}`;
console.log({dir_path});
fs.mkdirSync(dir_path, { recursive: true });

fs.writeFileSync(dir_path + "/food-items.json", food_items_text);

// create recipe's from the food items
let recipe_response = await openai.chat.completions.create({
  model: "gpt-4o",
  messages: [
	{
	  role: "system",
	  content: `Create multiple recipes for meals using the food items that the user provides using this format in a single array of json object.
				Assume the user has no knowledge of cooking and is a beginner, so fill the instructions with as much detail as possible.
				Make sure that the instructions for the recipe are clear and detailed enough to be followed by someone who is not a professional chef.
				if there might be specific instructions for items included in their packaging, give them the instructions for doing that activity along with pointing them to the package in case the instructions differ.
	  			Include an image prompt to use to generate a good image of the finished recipe in image_prompt.
				Generate a unique id for each recipe, if the recipe has been generated before, reuse the same id.
				Do not hold back because you are conserned about the content not fitting into a single response, you can spread the data accross multiple responses, just make sure that there is no seperation between the data that is that the data is continuous between the responses.
				format is as follows:
		  		{ "name": text, id: text, image_prompt: text, duration: number, servings: number, "ingredients": {name: text, quantity: number, displayed_text: text, already_have: bool}, "instructions": [text] }`,
	},
	{
	  role: "user",
	  content: fs.readFileSync("./runs/run-2/food-items.json", "utf-8")
	},
  ],
});

let [recipes, recipes_text] = extract_json(recipe_response);

fs.writeFileSync(dir_path + "/recipes.json", recipes_text);
console.log({ recipes });

const recipe_image_dir = dir_path + "/recipe-images";

fs.mkdirSync(recipe_image_dir, { recursive: true });

for (let recipe of recipes) {

  const recipe_image_form_data = {
	prompt: "a zoomed out image showing the full dish of " + recipe.image_prompt,
	output_format: "jpeg",
	model: "sd3",
  };

  console.log(recipe_image_form_data.prompt);

  const response = await axios.postForm(
	`https://api.stability.ai/v2beta/stable-image/generate/sd3`,
	axios.toFormData(recipe_image_form_data, new FormData()),
	{
	  validateStatus: undefined,
	  responseType: "arraybuffer",
	  headers: {
		Authorization: `Bearer ${process.env.STABILITY_API_KEY}`,
		Accept: "image/*",
	  },
	}
  );

  if (response.status === 200) {
	fs.writeFileSync(recipe_image_dir + `/${recipe.name}.jpeg`, Buffer.from(response.data));
  } else {
	throw new Error(`${response.status}: ${response.data.toString()}`);
  }
}
