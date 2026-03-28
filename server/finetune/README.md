# Ounje Recipe Model Training

This folder contains the practical training assets for Ounje's recipe model work.

## Files

- `recipe_corpus.json`
  - full exported recipe corpus from Supabase
- `recipe_style_examples.jsonl`
  - full supervised fine-tuning dataset for recipe structure and formatting
- `recipe_style_train.jsonl`
  - train split for OpenAI fine-tuning
- `recipe_style_valid.jsonl`
  - validation split for OpenAI fine-tuning
- `recipe_adaptation_prompts.jsonl`
  - sidecar adaptation tasks used for prompt-time testing and future synthetic training

## What the fine-tune should learn

The supervised fine-tune is for recipe shape and style:

- title
- summary
- recipe type
- dietary tags
- cuisine tags
- cook time
- ingredient formatting
- instruction formatting

## What stays at inference time

Recipe adaptation is currently handled by:

- the live recipe corpus
- FlavorGraph ingredient-pairing priors
- user dietary/profile constraints
- an LLM adaptation prompt

This is better than supervised fine-tuning alone for requests like:

- make it spicier
- make it quicker
- make it higher-protein
- make it vegetarian

because those tasks need live constraints and retrieval-time reasoning.

## Commands

Rebuild the graph index:

```bash
npm run flavorgraph:index
```

Re-export the current recipe corpus and training splits:

```bash
npm run recipes:export-corpus
```

Create a fine-tune job:

```bash
npm run recipes:create-finetune
```

Refresh and inspect the active fine-tune status / model registry:

```bash
npm run recipes:status
```

Custom model / files:

```bash
node server/scripts/create_recipe_finetune_job.mjs \
  --training-file server/finetune/recipe_style_train.jsonl \
  --validation-file server/finetune/recipe_style_valid.jsonl \
  --model gpt-4.1-mini-2025-04-14 \
  --suffix ounje-recipe-style
```

## Runtime model routing

- Discover intent stays on the base model.
- Recipe shaping and recipe adaptation use the active recipe rewrite model from:
  - `server/config/recipe-models.json`
- When the configured fine-tune job finishes successfully, the server automatically promotes the fine-tuned model into the active recipe rewrite slot.
