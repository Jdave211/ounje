import { SafeImage } from "../../components/safe-image.jsx";
import { RecipeActions } from "../../components/recipe-actions.jsx";
import { OriginalSourcePrompt } from "../../components/original-source-prompt.jsx";
import {
  buildRecipeJSONLD,
  ingredientMonogram,
  serializeJSONForHTML,
} from "../../../lib/recipe-schema.js";

function Metric({ label, value }) {
  return (
    <div className="metric" data-testid="recipe-metric">
      <span className="metric__label">{label}</span>
      <strong className="metric__value">{value}</strong>
    </div>
  );
}

function Ingredient({ ingredient }) {
  return (
    <li className="ingredient" data-testid="ingredient-item">
      <SafeImage
        src={ingredient.imageURL}
        alt={ingredient.imageURL ? ingredient.name : ""}
        className="ingredient__visual"
        fallbackText={ingredientMonogram(ingredient.name)}
      />
      <span className="ingredient__name">{ingredient.name}</span>
      {ingredient.quantity ? <span className="ingredient__quantity">{ingredient.quantity}</span> : null}
    </li>
  );
}

function Step({ step }) {
  return (
    <li className="step" data-testid="cooking-step">
      <span className="step__number" aria-hidden="true">{String(step.number).padStart(2, "0")}</span>
      <div className="step__copy">
        <p>{step.instruction}</p>
        {step.tip ? <p className="step__tip">{step.tip}</p> : null}
      </div>
    </li>
  );
}

export function RecipeSharePage({ recipe, canonicalURL }) {
  const jsonLD = buildRecipeJSONLD(recipe, canonicalURL);

  return (
    <main className="share-shell">
      <section className="hero-stage" aria-label={`${recipe.title} image`}>
        <SafeImage
          src={recipe.heroURL}
          alt={recipe.heroURL ? recipe.imageCaption || recipe.title : ""}
          className={`hero-image${recipe.usesSquircleHero ? " hero-image--squircle" : ""}`}
          fallbackText="Ounje"
          priority
        />
      </section>

      <article className="recipe-content">
        <header className="recipe-heading">
          <h1 className="recipe-title">{recipe.title}</h1>
          <div className="recipe-source-line">
            <span>{recipe.creator}</span>
            {recipe.originalSourceURL ? (
              <>
                <span className="recipe-source-line__separator" aria-hidden="true">•</span>
                <OriginalSourcePrompt
                  href={recipe.originalSourceURL}
                  sourceKind={recipe.originalSourceKind}
                />
              </>
            ) : null}
          </div>
          <RecipeActions canonicalURL={canonicalURL} />
          {recipe.description ? <p className="recipe-description">{recipe.description}</p> : null}
        </header>

        <section className="recipe-section" aria-labelledby="details-heading">
          <h2 id="details-heading">Details</h2>
          <div className="metrics-grid">
            {recipe.metrics.map((metric) => <Metric key={metric.label} {...metric} />)}
          </div>
        </section>

        <section className="recipe-section ingredients-section" aria-labelledby="ingredients-heading">
          <h2 id="ingredients-heading">Ingredients</h2>
          <ul className="ingredients-grid">
            {recipe.ingredients.map((ingredient) => <Ingredient key={ingredient.id} ingredient={ingredient} />)}
          </ul>
        </section>

        <section className="recipe-section steps-section" aria-labelledby="steps-heading">
          <h2 id="steps-heading">Cooking Steps</h2>
          <ol className="steps-list">
            {recipe.steps.map((step, index) => <Step key={`${step.number}-${index}`} step={step} />)}
          </ol>
        </section>
      </article>

      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: serializeJSONForHTML(jsonLD) }}
      />

    </main>
  );
}
