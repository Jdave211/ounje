import OpenAi from "openai";
import { EDIT_DESCRIPTION_AND_INSTRUCTIONS_PROMPT } from "./prompts";

export const openai = new OpenAi({
  apiKey: process.env.OPENAI_API_KEY,
});

export const format_generated_recipe = (recipe) => {
  recipe.is_generated = true;
  recipe.is_approved = false;
  recipe.source_url = "";
  recipe.aggregate_likes = 0;
  recipe.spoonacular_source_url = null;
  recipe.spoonacular_score = null;
  recipe.license = null;
  recipe.weight_watcher_smart_points = null;
  recipe.taste = null;
  recipe.original_id = null;
  recipe.author = null;
  recipe.approved = null;
  recipe.analyzed_instructions = [];
  recipe.source_name = "chatgpt model gpt-4o";
  return recipe;
};

export const format_spoonacular_recipe = async (recipe) => {
  if (
    recipe.description &&
    typeof recipe.instructions === "object" &&
    recipe.instructions.length > 0
  ) {
    return recipe;
  }

  const system_prompt = {
    role: "system",
    content: EDIT_DESCRIPTION_AND_INSTRUCTIONS_PROMPT,
  };

  const response = await openai.chat.completions.create({
    model: "gpt-4o",
    messages: [
      system_prompt,
      {
        role: "user",
        content: JSON.stringify(recipe),
      },
    ],
    response_format: { type: "json_object" },
  });

  const response_details = response.choices[0].message.content;

  const { description, instructions } = JSON.parse(response_details);
  recipe.description = description;
  recipe.instructions = instructions;
  return recipe;
};
export const extract_json = (data) => {
  console.log("OpenAI API response data: ", data);

  const content = data.choices.map((choice) => choice.message.content).join("");
  const regex = /^```json([\s\S]*?)^```/gm;
  const matches = regex.exec(content);

  let json_text = matches?.[0].replace(/^```json\n|\n```$/g, "") || content; // Remove the code block markers
  console.log("Extracted JSON text: ", json_text);
  
  let object;
  try {
    object = JSON.parse(json_text);
  } catch (error) {
    console.error("Error parsing JSON: ", error, json_text);
    throw new Error("Failed to parse JSON from OpenAI response");
  }

  return {
    object,
    text: json_text,
  };
};

export const flatten_nested_objects = (nestedObject, keys) => {
  const flatten = (obj, keys, parentKeys = {}) => {
    if (keys.length === 0) {
      return obj.map((item) => ({ ...parentKeys, ...item }));
    }

    const [currentKey, ...remainingKeys] = keys;
    const entries = Object.entries(obj);

    return entries.flatMap(([key, value]) => {
      const newParentKeys = { ...parentKeys, [currentKey]: key };
      return flatten(value, remainingKeys, newParentKeys);
    });
  };

  return flatten(nestedObject, keys);
};
