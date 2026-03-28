import fs from 'node:fs';
import path from 'node:path';
import OpenAI from 'openai';

const apiKey = process.env.OPENAI_API_KEY;
if (!apiKey) {
  console.error('OPENAI_API_KEY is required');
  process.exit(1);
}

const DEFAULT_TRAINING_FILE = '/Users/davejaga/Desktop/startups/ounje/server/finetune/recipe_style_train.jsonl';
const DEFAULT_VALIDATION_FILE = '/Users/davejaga/Desktop/startups/ounje/server/finetune/recipe_style_valid.jsonl';

const args = process.argv.slice(2);
let trainingFile = DEFAULT_TRAINING_FILE;
let validationFile = DEFAULT_VALIDATION_FILE;
let model = 'gpt-4.1-mini-2025-04-14';
let suffix = 'ounje-recipe-style';

for (let i = 0; i < args.length; i += 1) {
  const arg = args[i];
  if (arg === '--training-file' && args[i + 1]) trainingFile = args[++i];
  else if (arg === '--validation-file' && args[i + 1]) validationFile = args[++i];
  else if (arg === '--model' && args[i + 1]) model = args[++i];
  else if (arg === '--suffix' && args[i + 1]) suffix = args[++i];
  else if (!arg.startsWith('--') && trainingFile === DEFAULT_TRAINING_FILE) trainingFile = arg;
  else if (!arg.startsWith('--') && model === 'gpt-4.1-mini-2025-04-14') model = arg;
}

if (!fs.existsSync(trainingFile)) {
  console.error(`Training file not found: ${trainingFile}`);
  process.exit(1);
}

const client = new OpenAI({ apiKey });
const registryPath = path.resolve('/Users/davejaga/Desktop/startups/ounje/server/config/recipe-models.json');

const uploaded = await client.files.create({
  file: fs.createReadStream(trainingFile),
  purpose: 'fine-tune',
});

let validationFileId = null;
if (validationFile && fs.existsSync(validationFile)) {
  const uploadedValidation = await client.files.create({
    file: fs.createReadStream(validationFile),
    purpose: 'fine-tune',
  });
  validationFileId = uploadedValidation.id;
}

const job = await client.fineTuning.jobs.create({
  training_file: uploaded.id,
  ...(validationFileId ? { validation_file: validationFileId } : {}),
  model,
  suffix,
});

console.log(JSON.stringify({
  training_file: uploaded.id,
  validation_file: validationFileId,
  job_id: job.id,
  model,
  suffix,
}, null, 2));

if (fs.existsSync(registryPath)) {
  const registry = JSON.parse(fs.readFileSync(registryPath, 'utf8'));
  registry.fineTune = {
    ...(registry.fineTune ?? {}),
    jobId: job.id,
    status: 'queued',
    fineTunedModel: null,
    lastCheckedAt: null,
    completedAt: null,
    error: null,
    trainingFile: uploaded.id,
    validationFile: validationFileId,
  };
  registry.models = {
    ...(registry.models ?? {}),
    recipeRewriteBaseModel: model,
  };
  fs.writeFileSync(registryPath, JSON.stringify(registry, null, 2));
}
