#!/usr/bin/env python3
import json
import os
import random
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path('/Users/davejaga/Desktop/startups/ounje')
ENV = ROOT / 'server' / '.env'
OUT_DIR = ROOT / 'server' / 'finetune'
OUT_DIR.mkdir(parents=True, exist_ok=True)

vals = {}
for line in ENV.read_text().splitlines():
    if '=' in line and not line.strip().startswith('#'):
        k, v = line.split('=', 1)
        vals[k.strip()] = v.strip().strip('"').strip("'")

SUPABASE_URL = vals['SUPABASE_URL'].rstrip('/')
SUPABASE_ANON_KEY = vals['SUPABASE_ANON_KEY']
HEADERS = {
    'apikey': SUPABASE_ANON_KEY,
    'Authorization': 'Bearer ' + SUPABASE_ANON_KEY,
}


def fetch_page(offset, limit=500):
    select = ','.join([
        'id','title','description','recipe_type','category','cook_time_text','ingredients_text','instructions_text',
        'flavor_tags','dietary_tags','cuisine_tags','source','recipe_url'
    ])
    url = f"{SUPABASE_URL}/rest/v1/recipes?select={urllib.parse.quote(select)}&order=updated_at.desc.nullslast,published_date.desc.nullslast&limit={limit}&offset={offset}"
    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)

recipes = []
offset = 0
while True:
    page = fetch_page(offset)
    if not page:
        break
    recipes.extend(page)
    offset += len(page)
    if len(page) < 500:
        break

corpus_path = OUT_DIR / 'recipe_corpus.json'
style_path = OUT_DIR / 'recipe_style_examples.jsonl'
adapt_path = OUT_DIR / 'recipe_adaptation_prompts.jsonl'
style_train_path = OUT_DIR / 'recipe_style_train.jsonl'
style_valid_path = OUT_DIR / 'recipe_style_valid.jsonl'

corpus_path.write_text(json.dumps(recipes, indent=2))

style_records = []
adapt_records = []

for recipe in recipes:
        title = recipe.get('title') or 'Untitled Recipe'
        recipe_type = recipe.get('recipe_type') or ''
        dietary_tags = recipe.get('dietary_tags') or []
        cuisines = recipe.get('cuisine_tags') or []
        ingredients = recipe.get('ingredients_text') or ''
        instructions = recipe.get('instructions_text') or ''
        cook_time = recipe.get('cook_time_text') or ''
        description = recipe.get('description') or ''

        style_record = {
            'messages': [
                {
                    'role': 'system',
                    'content': 'Return a clean, complete meal-prep-ready recipe object with title, summary, recipe_type, dietary_tags, cuisine_tags, cook_time_text, ingredients_text, and instructions_text.'
                },
                {
                    'role': 'user',
                    'content': f"Create a proper recipe entry for: {title}. Type: {recipe_type}. Cuisines: {', '.join(cuisines)}. Dietary tags: {', '.join(dietary_tags)}."
                },
                {
                    'role': 'assistant',
                    'content': json.dumps({
                        'title': title,
                        'summary': description,
                        'recipe_type': recipe_type,
                        'dietary_tags': dietary_tags,
                        'cuisine_tags': cuisines,
                        'cook_time_text': cook_time,
                        'ingredients_text': ingredients,
                        'instructions_text': instructions,
                    }, ensure_ascii=False)
                }
            ]
        }
        style_records.append(style_record)

        adapt_prompt_record = {
            'recipe_id': recipe.get('id'),
            'title': title,
            'base_recipe': {
                'recipe_type': recipe_type,
                'cuisine_tags': cuisines,
                'dietary_tags': dietary_tags,
                'cook_time_text': cook_time,
                'ingredients_text': ingredients,
                'instructions_text': instructions,
            },
            'adaptation_tasks': [
                'make it spicier without breaking the dish',
                'make it faster for meal prep',
                'make it higher-protein while keeping the spirit of the recipe',
                'make it vegetarian if possible',
            ],
        }
        adapt_records.append(adapt_prompt_record)

random.Random(42).shuffle(style_records)
valid_size = max(50, int(len(style_records) * 0.1))
valid_records = style_records[:valid_size]
train_records = style_records[valid_size:]

with style_path.open('w') as f_style:
    for style_record in style_records:
        f_style.write(json.dumps(style_record, ensure_ascii=False) + '\n')

with style_train_path.open('w') as f_train:
    for style_record in train_records:
        f_train.write(json.dumps(style_record, ensure_ascii=False) + '\n')

with style_valid_path.open('w') as f_valid:
    for style_record in valid_records:
        f_valid.write(json.dumps(style_record, ensure_ascii=False) + '\n')

with adapt_path.open('w') as f_adapt:
    for adapt_prompt_record in adapt_records:
        f_adapt.write(json.dumps(adapt_prompt_record, ensure_ascii=False) + '\n')

print(f'exported {len(recipes)} recipes')
print(corpus_path)
print(style_path)
print(style_train_path)
print(style_valid_path)
print(adapt_path)
