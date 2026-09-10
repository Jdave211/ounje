import assert from 'node:assert/strict';
process.env.OPENAI_API_KEY='';process.env.SUPABASE_URL='https://dedupe-test.invalid';process.env.SUPABASE_ANON_KEY='test';process.env.SUPABASE_SERVICE_ROLE_KEY='';process.env.REDIS_DISABLED='true';
const first='https://www.tiktok.com/@one/video/1111111111111111111';
const second='https://www.tiktok.com/@two/video/2222222222222222222';
let existing={id:'uir_existing',title:'Chocolate Cake',user_id:'user-test',source:'tiktok',original_recipe_url:first,recipe_url:first,dedupe_key:'old-key'};
const requests=[];
globalThis.fetch=async (url,options={})=>{
 const u=new URL(url);assert.equal(u.hostname,'dedupe-test.invalid');assert.equal(options.method??'GET','GET');requests.push(u);
 let matches=true;
 for(const [key,filter] of u.searchParams){
  if(['select','limit','order'].includes(key))continue;
  if(filter.startsWith('eq.'))matches &&= String(existing[key]??'')===filter.slice(3);
  else if(filter.startsWith('in.'))matches &&= filter.includes(String(existing[key]??'not-present'));
  else if(filter.startsWith('ilike.'))matches &&= String(existing[key]??'').toLowerCase()===filter.slice(6).toLowerCase();
 }
 return new Response(JSON.stringify(matches?[existing]:[]),{status:200,headers:{'content-type':'application/json'}});
};
const {findExistingUserImportedRecipe,completedImportJobHasLiveRecipe}=await import('../lib/recipe-ingestion.js');
const fresh={title:existing.title,source:'tiktok',original_recipe_url:second,recipe_url:second};
assert.equal(await findExistingUserImportedRecipe('user-test',fresh,'new-key'),null,'same title on different posts must not replace fresh extraction');
assert.ok(!requests.some(u=>u.searchParams.has('title')),'title is never a user import identity');
assert.equal((await findExistingUserImportedRecipe('user-test',{...fresh,recipe_url:first,original_recipe_url:first},'old-key'))?.id,existing.id,'same source still deduplicates');
assert.equal(await findExistingUserImportedRecipe('another-user',{...fresh,recipe_url:first,original_recipe_url:first},'old-key'),null,'deduplication stays user-scoped');
assert.equal(await findExistingUserImportedRecipe('user-test',fresh,'old-key'),null,'even a stale key cannot override conflicting source identity');
assert.equal(await completedImportJobHasLiveRecipe({status:'saved',recipe_id:existing.id,canonical_url:second}),false,'reject old cached job pointing to another post');
assert.equal(await completedImportJobHasLiveRecipe({status:'saved',recipe_id:existing.id,canonical_url:first}),true);
for(const [a,b] of [['https://www.instagram.com/reel/AAA/','https://www.instagram.com/reel/BBB/'],['https://www.youtube.com/watch?v=AAA','https://youtu.be/BBB']]){
 existing={...existing,recipe_url:a,original_recipe_url:a};
 assert.equal(await completedImportJobHasLiveRecipe({status:'saved',recipe_id:existing.id,canonical_url:b}),false,'source conflict protection applies across social platforms');
}
existing={...existing,recipe_url:'https://www.youtube.com/watch?v=AAA',original_recipe_url:'https://www.youtube.com/watch?v=AAA'};
assert.equal(await completedImportJobHasLiveRecipe({status:'saved',recipe_id:existing.id,canonical_url:'https://youtu.be/AAA'}),true,'equivalent URLs for one video remain reusable');
console.log('import dedupe: title collision, user scope, stale keys/caches and social URL aliases passed');
