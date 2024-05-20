const flattenNestedObjects = (nestedObject, keys) => {
  const flatten = (obj, keys, parentKeys = {}) => {
    if (keys.length === 0) {
      console.log({ obj });
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

// Example usage
const food_items = {
  fridge: {
    fruits: [
      { name: "apple", quantity: 5 },
      { name: "banana", quantity: 7 },
    ],
    vegetables: [{ name: "carrot", quantity: 10 }],
  },
  pantry: {
    grains: [{ name: "rice", quantity: 20 }],
    spices: [{ name: "pepper", quantity: 15 }],
  },
};

const keys = ["inventory", "category"];

const flattenedRecords = flattenNestedObjects(food_items, keys);

console.log(flattenedRecords);
