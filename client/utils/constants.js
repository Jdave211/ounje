export const FOOD_ITEMS = {
  refrigerator: {
    freezer_section: [
      { name: "frozen meats", quantity: 3 },
      { name: "frozen vegetables", quantity: 2 },
      { name: "ice packs", quantity: 1 },
    ],
    main_section: [
      { name: "yogurt", quantity: 2 },
      { name: "cheese blocks", quantity: 2 },
      { name: "orange juice", quantity: 1 },
      { name: "tomato sauce bottle", quantity: 1 },
      { name: "cold cuts", quantity: 1 },
      { name: "slices of cheese", quantity: 1 },
    ],
    crisper_drawer: [
      { name: "apples", quantity: 3 },
      { name: "avocado", quantity: 1 },
      { name: "citrus fruits", quantity: 3 },
    ],
    door: [
      { name: "beers", quantity: 9 },
      { name: "soda cans", quantity: 3 },
      { name: "bottled beverages", quantity: 3 },
    ],
  },
  pantry_cupboard: {
    top_shelf: [
      { name: "applesauce jar", quantity: 1 },
      { name: "pickled vegetables jar", quantity: 1 },
      { name: "corn can", quantity: 1 },
      { name: "green beans can", quantity: 1 },
      { name: "tomato can", quantity: 1 },
      { name: "carrot jar", quantity: 1 },
      { name: "baby potatoes jar", quantity: 1 },
    ],
  },
};

export const RECIPE = {
  Recipe: "Pasta with Tomato Sauce",
  CookTime: 25,
  Servings: 16,
  Calories: 250,
  Ingredients: [
    "1 cup bulgur wheat",
    "2 cups coarsely crumbled stale whole-wheat bread",
    "1 can garbanzo beans (16 oz) drained",
    "1 large lemon juiced",
    "2 large garlic cloves finely chopped",
    "4 tablespoons fresh cilantro chopped",
    "1 teaspoon red pepper flakes crushed",
    "1 teaspoon ground cumin",
    "1 teaspoon freshly ground black pepper",
    "1 cup scallions finely chopped",
    "1 teaspoon salt",
    "Vegetable oil for frying",
    "4 rounds pita bread warmed and halved",
    "2 tomatoes sliced",
    "1 cucumber julienned",
    "1 bell pepper thinly sliced",
    "1 bell pepper thinly sliced",
    "3 scallions shredded",
    "1 cup lettuce loosely packed finely shredded",
    "1 cup tahini or yoghurt sauce"
],
  Instructions: "Makes about thirty 1-inch balls\nIn a bowl, cover the bulgur with cold water and allow to soak for 30 minutes. while the bulgur is soaking, put the bread in another bowl, cover with cold water and soak for 15 minutes. Drain the bread in a colander, squeezing out the excess moisture. Drain the bulgur well through a fine sieve. In the bowl of a food processor fitted with the metal chopping blade, combine the garbanzos, lemon juice, garlic, cilantro, pepper flakes, cumin, black pepper and scallions. Process with an off-on motion until the mixture is finely chopped. Transfer the mixture to a bowl. Stir in the bulgur and bread\nHeat 1 inch of oil in a heavy 12 inch skillet over medium high heat until very hot but not smoking. Add the patties to the pan without crowding and fry for 2-3 minutes, turning once, until golden brown all over. As the patties brown, transfer to paper towels to drain and keep warm while frying the remainder. To serve, tuck 3-4 balls or patties in each pita half. Add several slices of tomato, cucumber, and bell pepper, and a sprinkling of scallions and lettuce. Drizzle with the tahini and 4NOTES : These are Delicious for Dinner with Hummus and Tabouli Salad.\nNOTES : These are Delicious for Dinner with Hummus and Tabouli Salad.\nHealthy and Fairly Low Fat.\nThe red pepper flakes gives this Middle Eastern Favorite a slow burn...a perfect partner for garlic-yogurt sauce or tahini.\n ",
  Summary: "This is a great recipe for a Middle Eastern favorite that is healthy and fairly low fat. The red pepper flakes give this dish a slow burn, making it a perfect partner for garlic-yogurt sauce or tahini. This recipe makes about thirty 1-inch balls, and is delicious for dinner with hummus and tabouli salad.",
};

export const GPT_RECIPE = {
  Recipe: "Vegan Chocolate Cake",
  CookTime: 35,
  Servings: 8, 
  Calories: 200, 
  Ingredients: [
    "1 1/2 cups all-purpose flour", 
    "1 cup granulated sugar", 
    "1/4 cup cocoa powder", 
    "1 teaspoon baking soda", 
    "1/2 teaspoon salt", 
    "1 teaspoon vanilla extract", 
    "1 tablespoon vinegar", 
    "1/3 cup vegetable oil", 
    "1 cup water",
  ], 
  Instructions: "1. Preheat the oven to 350°F (175°C). Grease an 8-inch round cake pan.\\n2. In a large bowl, whisk together the flour, sugar, cocoa powder, baking soda, and salt.\\n3. Add the vanilla extract, vinegar, vegetable oil, and water. Mix until just combined.\\n4. Pour the batter into the prepared cake pan.\\n5. Bake for 30-35 minutes, or until a toothpick inserted into the center comes out clean.\\n6. Allow the cake to cool in the pan for 10 minutes before transferring to a wire rack to cool completely.", 
  Summary: "Vegan Chocolate Cake is a rich and moist dessert that is perfect for any occasion. This easy-to-make cake uses simple ingredients and is free from dairy and eggs, making it suitable for vegans.\"}",
};
