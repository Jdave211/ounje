import OpenAi from "openai";

export const openai = new OpenAi({
  apiKey: process.env.OPENAI_API_KEY,
});

export const extract_json = (data) => {
  console.log("messages: ", data.choices.length);

  const content = data.choices.map((choice) => choice.message.content).join("");
  const regex = /^```json([\s\S]*?)^```/gm;
  const matches = regex.exec(content);

  let json_text = matches?.[0].replace(/^```json\n|\n```$/g, "") || content; // Remove the code block markers
  console.log({ json_text });
  let object = JSON.parse(json_text);

  return {
    object,
    text: json_text,
  };
};
