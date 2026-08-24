"use client";

import { useEffect, useRef, useState } from "react";

export function SafeImage({
  src,
  alt,
  className = "",
  fallbackText = "OU",
  priority = false,
}) {
  const imageRef = useRef(null);
  const [loaded, setLoaded] = useState(false);
  const [failed, setFailed] = useState(false);
  const canRenderImage = Boolean(src) && !failed;

  useEffect(() => {
    setLoaded(false);
    setFailed(false);

    const image = imageRef.current;
    if (!src || !image?.complete) return;

    if (image.naturalWidth > 0) {
      setLoaded(true);
    } else {
      setFailed(true);
    }
  }, [src]);

  return (
    <span className={`safe-image ${className}`}>
      <span className="safe-image__fallback" aria-hidden="true">
        {fallbackText}
      </span>
      {canRenderImage ? (
        <img
          ref={imageRef}
          className={`safe-image__asset ${loaded ? "is-loaded" : "is-pending"}`}
          src={src}
          alt={alt}
          loading={priority ? "eager" : "lazy"}
          fetchPriority={priority ? "high" : "auto"}
          decoding="async"
          onLoad={() => {
            setFailed(false);
            setLoaded(true);
          }}
          onError={() => {
            setLoaded(false);
            setFailed(true);
          }}
        />
      ) : null}
    </span>
  );
}
