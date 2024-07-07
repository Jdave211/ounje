import axios from "axios";
import { Buffer } from "buffer";

export const generate_image = async (prompt) => {
  const image_form_data = {
    prompt: prompt,
    output_format: "jpeg",
    model: "sd3-large-turbo", // sd3-large
  };

  const response = await axios.postForm(
    `https://api.stability.ai/v2beta/stable-image/generate/sd3`,
    axios.toFormData(image_form_data, new FormData()),
    {
      validateStatus: undefined,
      responseType: "arraybuffer",
      headers: {
        Authorization: `Bearer ${process.env.STABILITY_API_KEY}`,
        Accept: "image/*",
      },
    }
  );

  if (response.status !== 200) {
    throw new Error(`${response.status}: ${response.data.toString()}`);
  }

  const recipe_image = Buffer.from(response.data);

  return recipe_image;
};
