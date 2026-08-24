"use client";

import { useRef } from "react";

const APP_STORE_URL = "https://apps.apple.com/app/id6504951799";

export function OriginalSourcePrompt({ href, sourceKind = "link" }) {
  const dialogRef = useRef(null);
  const triggerLabel = sourceKind === "video" ? "See original video" : "See original link";

  function openDialog() {
    if (!dialogRef.current?.open) dialogRef.current?.showModal();
  }

  function closeDialog() {
    dialogRef.current?.close();
  }

  function handleBackdropClick(event) {
    if (event.target === event.currentTarget) closeDialog();
  }

  return (
    <>
      <button
        className="original-source-trigger"
        type="button"
        onClick={openDialog}
        data-testid="original-source-trigger"
      >
        {triggerLabel}
      </button>

      <dialog
        ref={dialogRef}
        className="original-source-dialog"
        aria-labelledby="original-source-dialog-title"
        aria-describedby="original-source-dialog-description"
        onClick={handleBackdropClick}
        data-testid="original-source-dialog"
      >
        <div className="original-source-dialog__panel">
          <span className="original-source-dialog__logo-frame">
            <img
              className="original-source-dialog__logo"
              src="/brand/ounje-wordmark.png"
              alt="Ounje"
              width="900"
              height="260"
            />
          </span>
          <h2 id="original-source-dialog-title">
            Turn any TikTok into an actual recipe.
          </h2>
          <p id="original-source-dialog-description">
            Download Ounje for the ingredients and steps, or continue to the original video.
          </p>

          <div className="original-source-dialog__actions">
            <a
              className="original-source-dialog__action original-source-dialog__action--primary"
              href={APP_STORE_URL}
              target="_blank"
              rel="noreferrer"
              onClick={closeDialog}
              data-testid="original-source-download"
            >
              Download
            </a>
            <a
              className="original-source-dialog__action"
              href={href}
              target="_blank"
              rel="noreferrer"
              onClick={closeDialog}
              data-testid="original-source-proceed"
            >
              Proceed
            </a>
          </div>
        </div>
      </dialog>
    </>
  );
}
