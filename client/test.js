import axios from "axios";
import fs from "fs";
const api_key = "b06171b6b51349a2be39de7b49f23b86";

console.log({ key: api_key });

let data = {
  id: 3,
  created_at: "2024-05-19 02:05:32.40818+00",
  title: "Simple Chicken Salad",
  image_url:
    "https://kmvqftoebsmmkhxrgdye.supabase.co/storage/v1/object/public/recipe_images/Simple%20Chicken%20Salad/26.jpeg",
  duration: 15,
  servings: 2,
  instructions: [
    "1. Wash the mixed greens under cold water and dry them using a salad spinner or paper towels.",
    "2. Shred the leftover chicken into bite-sized pieces.",
    "3. In a large bowl, combine the mixed greens and shredded chicken.",
    "4. In a small bowl, mix together the salad dressing and yogurt until well combined.",
    "5. Drizzle the dressing mixture over the salad.",
    "6. Finely chop the cilantro and sprinkle it over the salad.",
    "7. Squeeze the juice of one lemon over the salad and toss everything together.",
  ],
  likes: 0,
  selected: 0,
  unique_id: "1a7e2e9c-4d5b-4cc9-adca-90bfa120f9aa",
  ingredients: [
    {
      name: "mixed greens",
      quantity: 1,
      already_have: true,
      displayed_text: "1 bag of mixed greens",
    },
    {
      name: "leftover chicken",
      quantity: 1,
      already_have: true,
      displayed_text: "1 cup of shredded leftover chicken",
    },
    {
      name: "salad dressing",
      quantity: 1,
      already_have: true,
      displayed_text: "2 tablespoons of salad dressing",
    },
    {
      name: "yogurt",
      quantity: 1,
      already_have: true,
      displayed_text: "1 tablespoon of yogurt",
    },
    {
      name: "cilantro",
      quantity: 1,
      already_have: true,
      displayed_text: "A handful of cilantro",
    },
    {
      name: "lemon",
      quantity: 1,
      already_have: true,
      displayed_text: "Juice of 1 lemon",
    },
  ],
  description: null,
  total_calories: null,
};
// axios
//   .post(
//     "https://api.spoonacular.com/recipes/analyzeInstructions",
//     JSON.stringify(data),
//     {
//       params: { apiKey: api_key },
//     }
//   )
//   .then((res) => {
//     console.log(res.data);
//     fs.writeFileSync("./recipe.txt", JSON.stringify(res.data), "utf-8");
//   })
//   .catch((res) => console.log(res.response));

const params = new URLSearchParams();
params.append(
  "ingredientList",
  data.ingredients.map((ingredient) => ingredient.displayed_text).join("\n")
);
params.append("servings", 1);

axios
  .post(
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
  )
  .then((res) => console.log(res.data));
