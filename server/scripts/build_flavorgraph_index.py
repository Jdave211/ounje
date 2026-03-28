#!/usr/bin/env python3
import csv
import json
import re
from collections import defaultdict
from pathlib import Path

ROOT = Path('/Users/davejaga/Desktop/startups/ounje')
NODES = ROOT / 'research' / 'flavorgraph' / 'assets' / 'nodes_191120.csv'
EDGES = ROOT / 'research' / 'flavorgraph' / 'assets' / 'edges_191120.csv'
OUT = ROOT / 'server' / 'data' / 'flavorgraph' / 'flavorgraph_index.json'

STOP = {
    'fat','fresh','ground','extra','virgin','table','inch','inches','cream','whole','boneless','skinless',
    'low','reduced','free','plain','large','small','medium','sweetened','unsalted','salted','powdered','dried'
}
ALIASES = {
    'scallions': 'green onion',
    'spring onion': 'green onion',
    'jalapenos': 'jalapeno',
    'chilies': 'chili',
    'chillies': 'chili',
    'bell peppers': 'bell pepper',
    'tomatoes': 'tomato',
    'potatoes': 'potato',
    'onions': 'onion',
    'mushrooms': 'mushroom',
    'avocados': 'avocado',
    'tortillas': 'tortilla',
    'chickpeas': 'chickpea',
    'black beans': 'black bean',
    'kidney beans': 'kidney bean',
}


def normalize(text: str) -> str:
    value = text.lower().replace('_', ' ')
    value = re.sub(r'\b\d+%?\b', ' ', value)
    value = re.sub(r'[^a-z\s-]', ' ', value)
    value = re.sub(r'\s+', ' ', value).strip()
    tokens = [t for t in value.split() if t not in STOP]
    value = ' '.join(tokens).strip()
    value = ALIASES.get(value, value)
    if value.endswith('es') and len(value) > 4 and value[:-2] not in ALIASES:
        singular = value[:-2]
        if singular.endswith('i'):
            singular = singular[:-1] + 'y'
        value = singular
    elif value.endswith('s') and len(value) > 3:
        value = value[:-1]
    return ALIASES.get(value, value)


nodes = {}
reverse_lookup = defaultdict(set)
with NODES.open(newline='') as f:
    reader = csv.DictReader(f)
    for row in reader:
        if row.get('node_type') != 'ingredient':
            continue
        raw = row.get('name') or ''
        normalized = normalize(raw)
        if not normalized:
            continue
        node_id = row['node_id']
        nodes[node_id] = {'raw': raw, 'normalized': normalized}
        reverse_lookup[normalized].add(raw)

adj = defaultdict(lambda: defaultdict(float))
with EDGES.open(newline='') as f:
    reader = csv.DictReader(f)
    for row in reader:
        if row.get('edge_type') != 'ingr-ingr':
            continue
        a = nodes.get(row['id_1'])
        b = nodes.get(row['id_2'])
        if not a or not b:
            continue
        if a['normalized'] == b['normalized']:
            continue
        score = float(row['score'])
        if score <= 0:
            continue
        if score > adj[a['normalized']][b['normalized']]:
            adj[a['normalized']][b['normalized']] = score
        if score > adj[b['normalized']][a['normalized']]:
            adj[b['normalized']][a['normalized']] = score

index = {}
for ingredient, neighbors in adj.items():
    top = sorted(neighbors.items(), key=lambda kv: kv[1], reverse=True)[:40]
    index[ingredient] = [
        {'ingredient': name, 'score': round(score, 6)}
        for name, score in top
    ]

payload = {
    'source': 'FlavorGraph official repo assets',
    'nodes_file': str(NODES.relative_to(ROOT)),
    'edges_file': str(EDGES.relative_to(ROOT)),
    'ingredient_count': len(index),
    'alias_count': len(reverse_lookup),
    'aliases': {k: sorted(v)[:8] for k, v in sorted(reverse_lookup.items())},
    'pairings': index,
}
OUT.write_text(json.dumps(payload, indent=2))
print(f'wrote {OUT}')
print(f'ingredients indexed: {len(index)}')
