import OpenAi from "openai";

export const openai = new OpenAi({
  apiKey: process.env.OPENAI_API_KEY,
});

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
