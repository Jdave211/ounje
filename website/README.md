# Ounje recipe-sharing website

Independent Next.js application for Ounje recipe share URLs. The only product route is `/r/[shareId]`.

## Architecture

- Next.js server components render the complete recipe and metadata on the server.
- The browser never receives a Supabase project key.
- The data query selects only `share_id`, `status`, and `snapshot_json` from `recipe_share_links`, and only for `status = active`.
- Missing, inactive, invalid, and malformed share records return the Ounje 404 page. Upstream failures return the Ounje 500 state.
- Stored snapshots are rendered as-is; the website does not read private recipe tables or repair snapshots from live recipe data.

## Local run

1. Copy `.env.example` to `.env.local` and fill the server-only values.
2. Run `npm install`.
3. Run `npm run dev` and open `http://localhost:3000/r/yQek7g_tAFvN`.

## Tests and production build

```sh
npm test
npm run build
```

## Vercel deployment

Set the Vercel Root Directory to `website` and add:

- `SUPABASE_URL`
- `SUPABASE_SECRET_KEY` (preferred) or `SUPABASE_SERVICE_ROLE_KEY` (legacy fallback)
- `OUNJE_WEBSITE_URL` with the final `https://…` host

Then deploy. No browser-exposed (`NEXT_PUBLIC_`) Supabase variable is used.

The production host is `https://ounje-recipe.vercel.app`. The previous `https://ounje-recipe-share.vercel.app` host remains active for existing links. The backend's `OUNJE_PUBLIC_BASE_URL` points to the shorter origin, and both iOS entitlement files register both hosts for Universal Links. The website serves `/.well-known/apple-app-site-association`, so newly created links open in Ounje when the app is installed and fall back to the complete web recipe otherwise.
