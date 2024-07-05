import axios from "axios";
import { supabase } from "./supabase";
import { objectToSnake } from "ts-case-convert";

// spoonacular api
export const fetchRecipeDetails = async (id) => {
  const {
    data: [recipe],
  } = await supabase.from("recipe_ids").select("*").eq("id", id).throwOnError();

  return recipe;
};

export const get_recipe_details = async (id) => {
  const { data: recipe } = await axios
    .get(`https://api.spoonacular.com/recipes/${id}/information`, {
      params: {
        includeNutrition: true,
      },
      headers: {
        "x-api-key": process.env.SPOONACULAR_API_KEY,
      },
    })
    .catch((error) => {
      console.error("get_recipe_details:", error, error.response.data);
      return null;
    });

  return recipe;
};

export const get_bulk_recipe_details = async (ids) => {
  let { data: recipe_options } = await axios
    .get(`https://api.spoonacular.com/recipes/informationBulk`, {
      params: {
        includeNutrition: true,
        ids: ids.join(", "),
      },
      headers: {
        "x-api-key": process.env.SPOONACULAR_API_KEY,
      },
    })
    .catch((error) => {
      console.error("get_bulk_recipe_details:", error, error.response.data);
      return null;
    });

  return recipe_options;
};
export const find_recipes_by_ingredients = async (ingredients) => {
  const { data: suggestedRecipes } = await axios.get(
    "https://api.spoonacular.com/recipes/findByIngredients",
    {
      params: {
        ingredients: ingredients.map(({ name }) => name).join(", "),
        number: 7,
        ranking: 1,
      },
      headers: {
        "x-api-key": process.env.SPOONACULAR_API_KEY,
      },
    }
  );

  const suggested_recipe_ids = suggestedRecipes.map((recipe) => recipe.id);

  const recipes = await get_bulk_recipe_details(suggested_recipe_ids);
  return recipes.map((recipe) => format_recipe(recipe));
};

export const format_recipe = (recipe) => {
  return objectToSnake(recipe);
};

export const parse_ingredients = async (ingredients) => {
  const params = new URLSearchParams();
  params.append("ingredientList", ingredients.join("\n"));
  params.append("includeNutrition", true);

  const { data } = await axios
    .post("https://api.spoonacular.com/recipes/parseIngredients", params, {
      headers: {
        "x-api-key": process.env.SPOONACULAR_API_KEY,
        "Content-Type": "application/x-www-form-urlencoded",
      },
    })
    .catch((error) => {
      console.error(
        "parse_ingredients:",
        error,
        error.response.data,
        error.response.message,
        error.message,
        error.request
      );
      throw error;
    });

  // Check if the data contains valid results
  if (!data || data.length === 0 || data.some((item) => !item.name)) {
    throw new Error("Invalid ingredient data returned from Spoonacular.");
  }

  return data.map(format_parsed_food_items);
};

export const flatten_nested_objects = (obj, path = []) => {
  const result = [];

  const traverse = (obj, path) => {
    for (let key in obj) {
      if (obj.hasOwnProperty(key)) {
        const newPath = path.concat(key);
        if (typeof obj[key] === "object" && obj[key] !== null) {
          traverse(obj[key], newPath);
        } else {
          result.push({ path: newPath.join("."), value: obj[key] });
        }
      }
    }
  };

  traverse(obj, path);
  return result;
};

export const format_parsed_food_items = (_parsed_food_item) => {
  const parsed_food_item = objectToSnake(_parsed_food_item);
  parsed_food_item.spoonacular_id = parsed_food_item.id;

  delete parsed_food_item.id;
  return parsed_food_item;
};