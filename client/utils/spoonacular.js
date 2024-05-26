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
    });

  return recipe;
};

export const get_bulk_recipe_details = async (ids) => {
  let { data: recipe_options } = await axios.get(
    `https://api.spoonacular.com/recipes/informationBulk`,
    {
      params: {
        apiKey: process.env.SPOONACULAR_API_KEY,
        includeNutrition: true,
        ids: ids.join(", "),
      },
    }
  );

  return recipe;
};

export const parse_ingredients = async (ingredients) => {
  const params = new URLSearchParams();
  params.append("ingredientList", ingredients);

  params.append("servings", 1);

  const { data } = axios.post(
    "https://api.spoonacular.com/recipes/parseIngredients",
    params,

    {
      params: {
        apiKey: api_key,
      },
      headers: {
        "Content-Type": "application/json",
      },
    }
  );

  return data;
};
