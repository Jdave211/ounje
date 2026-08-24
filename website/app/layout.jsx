import "./globals.css";

import { websiteBaseURL } from "../lib/share-data.js";

export const metadata = {
  metadataBase: websiteBaseURL(),
  title: "Ounje",
  description: "Shared recipes from Ounje.",
  applicationName: "Ounje",
};

export const viewport = {
  colorScheme: "dark",
  themeColor: "#121212",
  width: "device-width",
  initialScale: 1,
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
