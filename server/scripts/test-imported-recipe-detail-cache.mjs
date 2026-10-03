import assert from 'node:assert/strict';
process.env.OPENAI_API_KEY='';process.env.PERPLEXITY_API_KEY='';process.env.REDIS_URL='';process.env.REDIS_DISABLED='true';process.env.SUPABASE_URL='https://detail-cache-test.invalid';process.env.SUPABASE_ANON_KEY='test';process.env.SUPABASE_SERVICE_ROLE_KEY='test';
let row={id:'uir_cache_test',user_id:'owner',title:'Old recipe',description:'Mix a simple batter and cook until golden.',est_calories_text:'300 kcal per serving',updated_at:'2026-09-10T00:00:00Z',servings_count:2,servings_text:'2 servings',cook_time_text:'20 min',cook_time_minutes:20,prep_time_minutes:5,calories_kcal:300,protein_g:10,carbs_g:30,fat_g:12,ingredients_json:['flour','milk','egg'].map(name=>({display_name:name,quantity_text:'100 g',image_url:'https://images.example.com/ingredient.jpg'})),steps_json:[{number:1,text:'Mix flour, milk and egg into a smooth batter.'},{number:2,text:'Cook the batter in a pan until golden.'}]};
let owner='owner';let reads=0;
globalThis.fetch=async(input,options={})=>{
 const u=new URL(typeof input==='string'?input:input.url);assert.equal(u.hostname,'detail-cache-test.invalid');assert.equal(options.method??'GET','GET');
 if(u.pathname==='/auth/v1/user')return Response.json({id:owner});
 if(u.pathname==='/rest/v1/user_import_recipes'){reads++;assert.ok(u.searchParams.get('select').includes('updated_at'));return Response.json(row&&u.searchParams.get('user_id')===`eq.${row.user_id}`?[row]:[]);}
 return Response.json([]);
};
const {default:router}=await import('../api/v1/recipe.js');
const handler=router.stack.find(layer=>layer.route?.path==='/recipe/detail/:id').route.stack[0].handle;
const get=async()=>{let status=200,payload;const res={status(n){status=n;return this},json(p){payload=p;return this}};await handler({params:{id:'uir_cache_test'},headers:{authorization:`Bearer ${[ {alg:"HS256",typ:"JWT"}, {sub:owner,exp:Math.floor(Date.now()/1000)+3600}, "signature" ].map(v=>Buffer.from(typeof v==="string"?v:JSON.stringify(v)).toString("base64url")).join(".")}`},query:{}},res);return {status,payload};};
const first = await get();
assert.equal(first.status, 200);
assert.equal(first.payload.recipe.title, 'Old recipe');
await new Promise(resolve => setImmediate(resolve));
row={...row,title:'Unversioned test change'};
assert.equal((await get()).payload.recipe.title, 'Old recipe', 'fixture must exercise a warm cache');
row={...row,title:'Verified refreshed recipe',updated_at:'2026-09-10T01:00:00Z'};
assert.equal((await get()).payload.recipe.title,'Verified refreshed recipe','warm cache must follow persisted version');
owner='another-user';assert.equal((await get()).status,404,'cached owner content must not cross users');
owner='owner';row=null;assert.equal((await get()).status,404,'deleted recipe must not survive in a warm cache');
assert.equal(reads,5);console.log('import detail cache: refreshed version, owner isolation and deleted rows passed');
