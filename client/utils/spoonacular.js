import axios from "axios";

export const get_recipe_details = async (id) => {
  const { data: recipe } = await axios
    .get(`https://api.spoonacular.com/recipes/${id}/information`, {
      params: {
        apiKey: process.env.SPOONACULAR_API_KEY,
        includeNutrition: true,
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
        apiKey: process.env.SPOONACULAR_API_KEY,
        includeNutrition: true,
        ids: ids.join(", "),
      },
    })
    .catch((error) => {
      console.error("get_bulk_recipe_details:", error, error.response.data);
      return null;
    });

  return recipe_options;
};

export const parse_ingredients = async (ingredients) => {
  const params = new URLSearchParams();
  params.append("ingredientList", ingredients.join("\n"));
  params.append("servings", 1);

  try {
    const { data } = await axios.post(
      "https://api.spoonacular.com/recipes/parseIngredients",
      params,
      {
        params: {
          apiKey: process.env.SPOONACULAR_API_KEY,
        },
        headers: {
          "Content-Type": "application/json",
        },
      },
    );

    // Check if the data contains valid results
    if (!data || data.length === 0 || data.some((item) => !item.name)) {
      throw new Error("Invalid ingredient data returned from Spoonacular.");
    }
    console.log(data);
    return data;
  } catch (error) {
    console.error("parse_ingredients:", error);
    return null; // Return null if there's an error or invalid data
  }
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
