# Ounje recipe sharing · brand specification

> Collected from the iOS app on 2026-08-23. This website deliberately mirrors the recipe-detail product surface rather than creating a marketing interpretation.

## Core assets

### Handwritten mark and wordmark

- In-product mark: `public/fonts/Slee_handwritting-Regular.otf`, matching `SleeScriptDisplayText("Ounje")` in the iOS code.
- Static wordmark: `public/brand/ounje-wordmark.png`, copied from `OunjeLaunchWordmark.imageset` for unavailable states and non-font fallback contexts.
- App icon: `app/icon.png`, copied from the iOS AppIcon asset.
- Do not stretch, recolor, outline, or add effects beyond the subtle double-ink treatment already used by the iOS typography component.

## Palette

- Background: `#121212`
- Panel / quiet image fallback: `#1E1E1E`
- Cream: `#E9E0D2`
- Muted text: `#8A8A8A`
- Primary text: `#FFFFFF`
- Hairline: white at 8% opacity

These values come directly from `OunjePalette.swift`.

## Typography

- Ounje handwritten mark and ingredient names: Slee Handwriting.
- Recipe title and section headings: system serif, reflecting the iOS recipe typography and section-heading design.
- Metadata, quantities, and instructions: native system sans serif.

## Layout signature

- Circular food hero that bleeds beyond the right/top edge.
- Maximum 820px editorial recipe column.
- Flat 3-column details matrix.
- Square ingredient imagery; 3 columns at 320px, 4 columns at regular phone widths, 5 columns on tablet/desktop.
- Flat step rows with cream two-digit numbering and hairline dividers.

## Explicit exclusions

- No gradients, decorative blobs, recommendations, promotional panels, download pitch, dashboard chrome, nested cards, or discovery rails.
