"use client";

export default function ErrorPage({ reset }) {
  return (
    <main className="status-page">
      <img className="status-page__wordmark" src="/brand/ounje-wordmark.png" alt="Ounje" loading="lazy" />
      <h1>Recipe temporarily unavailable.</h1>
      <p>Ounje couldn’t load this recipe right now.</p>
      <button className="status-page__retry" type="button" onClick={() => reset()}>Try again</button>
    </main>
  );
}
