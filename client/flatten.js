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

const groupNestedObjects = (records, keys) => {
  const group = (records, keys) => {
    if (keys.length === 0) {
      return records;
    }

    const [currentKey, ...remainingKeys] = keys;
    return records.reduce((acc, record) => {
      const key = record[currentKey];
      if (!acc[key]) {
        acc[key] = [];
      }
      const { [currentKey]: _, ...rest } = record; // Remove the current key from the record
      acc[key].push(rest);
      return acc;
    }, {});
  };

  const buildNestedStructure = (groupedRecords, keys) => {
    if (keys.length === 0) {
      return groupedRecords;
    }

    const [currentKey, ...remainingKeys] = keys;
    const nestedStructure = {};

    for (const [key, records] of Object.entries(groupedRecords)) {
      nestedStructure[key] = buildNestedStructure(
        group(records, remainingKeys),
        remainingKeys,
      );
    }

    return nestedStructure;
  };

  return buildNestedStructure(group(records, keys), keys);
};

// Example usage
const records = [
  { inventory: "fridge", category: "fruits", name: "apple", quantity: 5 },
  { inventory: "fridge", category: "fruits", name: "banana", quantity: 7 },
  { inventory: "fridge", category: "vegetables", name: "carrot", quantity: 10 },
  { inventory: "pantry", category: "grains", name: "rice", quantity: 20 },
  { inventory: "pantry", category: "spices", name: "pepper", quantity: 15 },
];

const group_keys = ["inventory", "category"];

const groupedRecords = groupNestedObjects(records, group_keys);

console.log(JSON.stringify(groupedRecords, null, 2));
