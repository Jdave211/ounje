# FlavorGraph Notes For Ounje

Primary paper:
- `s41598-020-79422-8.pdf`

Repo assets copied here:
- `assets/nodes_191120.csv`
- `assets/edges_191120.csv`
- `assets/flavorgraph.png`
- `assets/flavorgraph2vec.png`
- `assets/embeddings.png`

What we are using from the paper in Ounje:
1. Ingredient-pairing priors from the ingredient-ingredient graph.
2. Embedding/ranking intuition for recipe discovery and retrieval.
3. Chemical-context-inspired pairing expansion for adaptation tasks.

What we are *not* doing:
- We are not retraining the original PyTorch graph model inside the app stack.
- We are distilling the published graph into a practical ingredient-pairing index and combining it with Ounje's live recipe corpus and LLM reasoning.

Ounje implementation files:
- `server/data/flavorgraph/flavorgraph_index.json`
- `server/lib/flavorgraph.js`
- `server/lib/recipe-corpus.js`
- `server/api/v1/recipe.js`
- `server/finetune/recipe_corpus.json`
- `server/finetune/recipe_style_examples.jsonl`
- `server/finetune/recipe_adaptation_prompts.jsonl`
