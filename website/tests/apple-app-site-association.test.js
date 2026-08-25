import { describe, expect, it } from "vitest";
import { appleAppSiteAssociation } from "../lib/apple-app-site-association.js";

describe("Apple app site association", () => {
  it("opens only recipe share routes in the Ounje app", () => {
    expect(appleAppSiteAssociation.applinks.details).toEqual([
      expect.objectContaining({
        appIDs: ["U8FPZXV6X6.net.ounje"],
        paths: ["/r/*"],
        components: [expect.objectContaining({ "/": "/r/*" })],
      }),
    ]);
  });
});
