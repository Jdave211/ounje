import axios from "axios";

const api_key = "b06171b6b51349a2be39de7b49f23b86";

console.log({ key: api_key });

axios
  .get("https://api.spoonacular.com/recipes/findByIngredients", {
    params: {
      apiKey: api_key,
      ingredients: "apples,flour,sugar",
      number: 5,
      ranking: 2,
    },
  })
  .then((res) => console.log(res.data));

axios
  .get("https://api.spoonacular.com/recipes/findByIngredients", {
    params: {
      apiKey: api_key,
      ingredients: "apples,flour,sugar",
      number: 5,
      ignorePantry: true,
    },
  })
  .then((res) => console.log(res.data));
