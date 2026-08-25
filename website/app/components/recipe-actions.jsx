"use client";

import { useEffect, useRef, useState } from "react";

const APP_STORE_URL = "https://apps.apple.com/app/id6504951799";

function fallbackCopy(value) {
  const input = document.createElement("textarea");
  input.value = value;
  input.setAttribute("readonly", "");
  input.style.position = "fixed";
  input.style.opacity = "0";
  document.body.appendChild(input);
  input.select();
  const didCopy = document.execCommand("copy");
  input.remove();
  if (!didCopy) throw new Error("Copy was not available.");
}

async function copyLink(value) {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(value);
    return;
  }
  fallbackCopy(value);
}

function ShareIcon() {
  return (
    <svg viewBox="0 0 20 20" aria-hidden="true">
      <path d="M10 2v10m0-10L6.5 5.5M10 2l3.5 3.5M5 9v7h10V9" />
    </svg>
  );
}

function SaveIcon() {
  return (
    <svg viewBox="0 0 20 20" aria-hidden="true">
      <path d="M5.5 3.25h9v13.5L10 13.9l-4.5 2.85V3.25Z" />
    </svg>
  );
}

export function RecipeActions({ canonicalURL }) {
  const [copied, setCopied] = useState(false);
  const resetTimer = useRef(null);

  useEffect(() => () => clearTimeout(resetTimer.current), []);

  async function handleShare() {
    try {
      await copyLink(canonicalURL);
      setCopied(true);
      clearTimeout(resetTimer.current);
      resetTimer.current = setTimeout(() => setCopied(false), 1800);
    } catch {
      setCopied(false);
    }
  }

  return (
    <div className="recipe-actions" aria-label="Recipe actions">
      <div className="recipe-actions__buttons">
        <button
          className="recipe-action-button"
          type="button"
          onClick={handleShare}
          aria-label="Copy recipe link"
          data-testid="copy-recipe-link"
        >
          <ShareIcon />
          <span>{copied ? "Copied" : "Share"}</span>
        </button>
        <a
          className="recipe-action-button"
          href={APP_STORE_URL}
          target="_blank"
          rel="noreferrer"
          aria-label="Save this recipe with Ounje on the App Store"
          data-testid="save-on-ounje-link"
        >
          <SaveIcon />
          <span>Save on Ounje</span>
        </a>
      </div>
      <span className="recipe-actions__status" role="status" aria-live="polite">
        {copied ? "Recipe link copied." : ""}
      </span>
    </div>
  );
}
