import { appleAppSiteAssociation } from "../../../lib/apple-app-site-association.js";

export function GET() {
  return Response.json(appleAppSiteAssociation, {
    headers: {
      "Cache-Control": "public, max-age=3600, s-maxage=86400",
    },
  });
}
