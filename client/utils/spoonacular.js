import axios from "axios";
import { supabase, fetchRecipes } from "./supabase";
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
        "x-api-key": process.env.EXPO_PUBLIC_SPOONACULAR_API_KEY,
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
        "x-api-key": process.env.EXPO_PUBLIC_SPOONACULAR_API_KEY,
      },
    })
    .catch((error) => {
      console.error("get_bulk_recipe_details:", error, error.response.data);
      return null;
    });

  return recipe_options;
};

export const find_recipes_by_ingredients = async (
  ingredients,
  max_recipes = 200,
  ranking = "maximize_owned_ingredients", // "minimum_missing_ingredients"
  ignorePantry = true
) => {
  const { data: suggestedRecipes } = await axios.get(
    "https://api.spoonacular.com/recipes/findByIngredients",
    {
      params: {
        ingredients: Array.isArray(ingredients)
        ? ingredients
            .filter(ingredient => ingredient != null && ingredient.name) // Check for null and presence of name
            .map(({ name }) => name)
            .join(", ")
        : "", 
        number: max_recipes,
        ranking: ranking === "maximize_owned_ingredients" ? 1 : 2,
        ignorePantry,
      },
      headers: {
        "x-api-key": process.env.EXPO_PUBLIC_SPOONACULAR_API_KEY,
      },
    }
  );

  const suggested_recipe_ids = suggestedRecipes.map((recipe) => recipe.id);

  const stored_suggested_recipes = await fetchRecipes(
    "spoonacular_id",
    suggested_recipe_ids
  );

  const stored_suggested_recipes_id_set = new Set();
  stored_suggested_recipes.forEach((recipe) =>
    stored_suggested_recipes_id_set.add(recipe?.spoonacular_id)
  );

  const new_recipe_ids = suggested_recipe_ids.filter(
    (id) => !stored_suggested_recipes_id_set.has(id)
  );

  const new_suggested_recipes = [];
  if (new_recipe_ids.length > 0) {
    const recipes = await get_bulk_recipe_details(suggested_recipe_ids);
    for (const recipe of recipes) {
      new_suggested_recipes.push(format_recipe(recipe));
    }
  }

  return { stored_suggested_recipes, new_suggested_recipes };
};

export const find_recipes_by_ingredients_and_store = async (ingredients) => {
  const suggested_recipes = await find_recipes_by_ingredients(ingredients);
  // todo: post processing recipes with chatgpt to update description and instructions before storing
  console.log({ suggested_recipes });
  const { data: recipes_with_ids } = await supabase
    .from("recipe_ids")
    .upsert(suggested_recipes, {
      onConflict: "spoonacular_id",
      ignoreDuplicates: true, // note: duplicates will be missing from returned data in recipes_with_ids
    })
    .select()
    .throwOnError();

  // const recipes_with_ids = await fetchRecipes(
  //   "spoonacular_id",
  //   suggested_recipes.map((recipe) => recipe.spoonacular_id)
  // );

  return recipes_with_ids;
};

export const extract_recipe_from_website = async (recipeUrl) => {
  try {
    const { data: recipe } = await axios.get(
      "https://api.spoonacular.com/recipes/extract",
      {
        params: {
          url: recipeUrl,
          // forceExtraction: true, // Optional: forces extraction even for supported sites
        },
        headers: {
          "x-api-key": process.env.EXPO_PUBLIC_SPOONACULAR_API_KEY, // Replace with your API key variable
        },
      }
    );

    // Format the recipe to match your database schema
    const formattedRecipe = format_recipe(recipe);
    console.log({ formattedRecipe });
    return formattedRecipe;
  } catch (error) {
    console.error(
      "extract_recipe_from_website:",
      error.response?.data || error.message
    );
    throw error;
  }
};

// export const extract_recipe_from_url = async (url) => {

export const format_recipe = (recipe_obj) => {
  const recipe = objectToSnake(recipe_obj);
  recipe.spoonacular_id = recipe.id;
  delete recipe.id;
  delete recipe.cheap;
  delete recipe.gaps;
  delete recipe.missed_ingredient_count;
  delete recipe.missed_ingredients;
  delete recipe.used_ingredients;
  delete recipe.used_ingredient_count;
  delete recipe.user_tags;
  delete recipe.unused_ingredients;
  delete recipe.unknown_ingredients;
  delete recipe.open_license;
  delete recipe.report;
  delete recipe.suspicious_data_score;
  console.log({ tips: recipe.tips });
  delete recipe.tips;
  return recipe;
};

export const parse_ingredients = async (ingredients) => {
  const params = new URLSearchParams();
  params.append("ingredientList", ingredients.join("\n"));
  params.append("includeNutrition", true);

  const { data } = await axios
    .post("https://api.spoonacular.com/recipes/parseIngredients", params, {
      headers: {
        "x-api-key": process.env.EXPO_PUBLIC_SPOONACULAR_API_KEY,
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
  if (!data || data.length === 0 || data.some((item) => !item?.name)) {
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
