import { websiteBaseURL } from "../lib/share-data.js";

export default function robots() {
  return {
    rules: {
      userAgent: "*",
      allow: "/r/",
      disallow: "/",
    },
    host: websiteBaseURL().toString(),
  };
}
