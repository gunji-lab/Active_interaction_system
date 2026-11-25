import { createClient } from '@supabase/supabase-js';
import QRCode from 'qrcode';
import './seminar.css';

const app=document.querySelector<HTMLDivElement>('#app')!;
const url=import.meta.env.VITE_SUPABASE_URL;
const key=import.meta.env.VITE_SUPABASE_ANON_KEY;
if(!url||!key){app.innerHTML='<main><h1>初期設定が必要です</h1><p>Supabaseの公開URLとキーを設定してください。</p></main>';throw Error('Missing Supabase configuration');}
const db=createClient(url,key);
type Item={id:string;body:string;author_name:string;status:'open'|'answered'|'hidden';created_at:string;like_count:number;liked?:boolean};
type Feed={error?:string;title?:string;is_open?:boolean;questions?:Item[]};
type Seminar={id:string;title:string;join_code:string;is_open:boolean;created_at:string};
let code=new URLSearchParams(location.search).get('code')?.trim().toUpperCase()||'';
let currentFeed:Feed|null=null;
let seminars:Seminar[]=[];
let selectedSeminar='';
let sortBy:'popular'|'newest'='popular';
let refreshTimer:number|undefined;
let busy=false;
const esc=(value:unknown)=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!));
const token=()=>{let value=localStorage.getItem('seminar-qa-token');if(!value){value=crypto.randomUUID();localStorage.setItem('seminar-qa-token',value);}return value;};
const notice=(text:string)=>{const node=document.querySelector<HTMLElement>('#notice');if(node)node.textContent=text;};
const shell=(body:string)=>{app.innerHTML=`<header><div class="qa-header"><a class="qa-brand" href="seminar.html">ラボゼミ <span>Q&A</span></a><nav><a href="index.html">講義レスポンス</a><a href="seminar.html?teacher=1">主催者</a></nav></div></header><main>${body}</main><footer>質問はゼミ参加者に公開されます。個人情報を書かないでください。</footer>`;};
const sortItems=(items:Item[])=>[...items].sort((a,b)=>sortBy==='popular'?b.like_count-a.like_count||Date.parse(b.created_at)-Date.parse(a.created_at):Date.parse(b.created_at)-Date.parse(a.created_at));
const dateText=(s:string)=>new Date(s).toLocaleString('ja-JP',{month:'numeric',day:'numeric',hour:'2-digit',minute:'2-digit'});
function itemHtml(q:Item,teacher=false){
 const status=q.status==='answered'?'<span class="qa-answered">回答済み</span>':q.status==='hidden'?'<span class="qa-hidden">非表示</span>':'';
 return `<article class="qa-question ${q.status==='hidden'?'is-hidden':''}" data-id="${q.id}"><div class="qa-question-top">${status}<time>${esc(dateText(q.created_at))}</time></div><p class="qa-question-body">${esc(q.body)}</p><div class="qa-question-bottom"><span class="qa-author">${esc(q.author_name)}</span><div class="qa-question-actions">${teacher?`<span class="qa-like-total">♥ ${q.like_count}</span>${q.status==='open'?`<button data-status="answered" data-id="${q.id}">回答済みにする</button>`:`<button data-status="open" data-id="${q.id}">再表示</button>`}${q.status!=='hidden'?`<button class="quiet" data-status="hidden" data-id="${q.id}">非表示</button>`:''}`:`<button class="qa-like ${q.liked?'liked':''}" data-like="${q.id}" aria-pressed="${!!q.liked}" aria-label="いいね ${q.like_count}件">♥ <span>${q.like_count}</span></button>`}</div></div></article>`;
}
function renderList(items:Item[],teacher=false){
 const list=document.querySelector<HTMLElement>('#question-list');if(!list)return;
 list.innerHTML=items.length?sortItems(items).map(q=>itemHtml(q,teacher)).join(''):'<div class="qa-empty">まだ質問はありません。最初の質問を投稿してみましょう。</div>';
 document.querySelectorAll<HTMLButtonElement>('[data-sort]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.sort===sortBy)));
}
function renderSort(){return `<div class="qa-sort"><span>並び順</span><button data-sort="popular" aria-pressed="${sortBy==='popular'}">いいね順</button><button data-sort="newest" aria-pressed="${sortBy==='newest'}">新着順</button></div>`;}
function wireSort(teacher=false){document.querySelectorAll<HTMLButtonElement>('[data-sort]').forEach(b=>b.onclick=()=>{sortBy=b.dataset.sort as 'popular'|'newest';renderList(teacher?teacherItems:currentFeed?.questions||[],teacher);});}
function joinUrl(s:Seminar){const u=new URL('seminar.html',location.href);u.search=`?code=${encodeURIComponent(s.join_code)}`;return u.href;}

async function student(){
 if(!code){shell(`<section class="qa-hero"><p class="qa-eyebrow">参加者向け</p><h1>ゼミで質問しよう</h1><p>質問を投稿したり、聞きたい質問に「いいね」できます。</p><form id="join"><label>参加コード<input name="code" maxlength="16" required autocomplete="off" placeholder="先生から共有されたコード"></label><button>参加する</button></form></section>`);document.querySelector<HTMLFormElement>('#join')!.onsubmit=e=>{e.preventDefault();const f=new FormData(e.currentTarget as HTMLFormElement);location.href=`seminar.html?code=${encodeURIComponent(String(f.get('code')).trim().toUpperCase())}`;};return;}
 await loadStudent();refreshTimer=window.setInterval(loadStudent,3000);
}
async function loadStudent(){
 if(busy)return;busy=true;
 const {data,error}=await db.rpc('seminar_feed',{p_code:code,p_token:token()});busy=false;
 if(error){if(!currentFeed)shell(`<section class="qa-card"><h1>読み込みに失敗しました</h1><p>${esc(error.message)}</p></section>`);else notice(error.message);return;}
 const feed=data as Feed;if(feed.error){shell(`<section class="qa-card"><h1>${esc(feed.error)}</h1><a href="seminar.html">コードを入力し直す</a></section>`);return;}
 const first=!currentFeed;currentFeed=feed;
 if(first)renderStudentShell();
 const status=document.querySelector<HTMLElement>('#qa-status');if(status)status.textContent=feed.is_open?'質問受付中':'質問受付終了';
 const form=document.querySelector<HTMLFormElement>('#post-form');if(form)form.hidden=!feed.is_open;
 const count=document.querySelector<HTMLElement>('#question-count');if(count)count.textContent=`${feed.questions?.length||0}件の質問`;
 renderList(feed.questions||[]);
}
function renderStudentShell(){
 const feed=currentFeed!;
 shell(`<section class="qa-title"><div><p class="qa-eyebrow">ゼミ質疑応答</p><h1>${esc(feed.title)}</h1><p><span class="qa-pill" id="qa-status"></span> · ${esc(code)}</p></div></section><div class="qa-grid"><section class="qa-card qa-compose"><h2>質問する</h2><form id="post-form"><label>表示名<input name="name" maxlength="40" required autocomplete="nickname" value="${esc(localStorage.getItem('seminar-qa-name')||'')}" placeholder="例：田中"></label><label>質問<textarea name="body" maxlength="1000" required rows="5" placeholder="聞きたいことを書いてください"></textarea></label><button class="primary">質問を投稿</button></form><p class="qa-hint">表示名は質問の下に小さく表示されます。</p><p id="notice" role="status"></p></section><section class="qa-card qa-feed"><div class="qa-feed-head"><div><h2>みんなの質問</h2><small id="question-count"></small></div>${renderSort()}</div><div id="question-list"></div></section></div>`);
 wireSort();
 document.querySelector<HTMLFormElement>('#post-form')!.onsubmit=async e=>{
  e.preventDefault();const form=e.currentTarget as HTMLFormElement;const f=new FormData(form);
  const name=String(f.get('name')||'').trim(),body=String(f.get('body')||'').trim();
  if(!name||!body){notice('表示名と質問を入力してください。');return;}
  const button=form.querySelector<HTMLButtonElement>('button')!;button.disabled=true;
  const {data,error}=await db.rpc('seminar_post',{p_code:code,p_token:token(),p_name:name,p_body:body});button.disabled=false;
  if(error||data?.error){notice(error?.message||data.error);return;}
  localStorage.setItem('seminar-qa-name',name);form.querySelector<HTMLTextAreaElement>('textarea')!.value='';notice('質問を投稿しました。');await loadStudent();
 };
 document.querySelector<HTMLElement>('#question-list')!.onclick=async e=>{
  const button=(e.target as HTMLElement).closest<HTMLButtonElement>('[data-like]');if(!button)return;
  button.disabled=true;const {data,error}=await db.rpc('seminar_toggle_like',{p_code:code,p_question_id:button.dataset.like,p_token:token()});
  if(error||data?.error){notice(error?.message||data.error);button.disabled=false;return;}
  await loadStudent();
 };
}

let teacherItems:Item[]=[];
async function teacher(){
 const {data:{session}}=await db.auth.getSession();if(!session){renderLogin();return;}
 await loadTeacher();refreshTimer=window.setInterval(refreshTeacher,3000);
}
function renderLogin(){
 shell(`<section class="qa-card qa-login"><p class="qa-eyebrow">主催者向け</p><h1>ログイン</h1><form id="login"><label>メールアドレス<input type="email" name="email" required autocomplete="username"></label><label>パスワード<input type="password" name="password" required autocomplete="current-password"></label><button class="primary">ログイン</button></form><p id="notice" role="status"></p></section>`);
 document.querySelector<HTMLFormElement>('#login')!.onsubmit=async e=>{e.preventDefault();const f=new FormData(e.currentTarget as HTMLFormElement);const {error}=await db.auth.signInWithPassword({email:String(f.get('email')),password:String(f.get('password'))});if(error)notice(error.message);else await start();};
}
async function loadTeacher(){
 const {data,error}=await db.from('seminars').select('*').order('created_at',{ascending:false});
 if(error){shell(`<section class="qa-card">${esc(error.message)}</section>`);return;}
 seminars=data||[];if(!seminars.some(s=>s.id===selectedSeminar))selectedSeminar=seminars[0]?.id||'';
 renderTeacher();await refreshTeacher();
}
function renderTeacher(){
 const s=seminars.find(x=>x.id===selectedSeminar);
 shell(`<section class="qa-title qa-title-admin"><div><p class="qa-eyebrow">主催者向け</p><h1>ゼミ Q&A 管理</h1></div><button class="quiet" id="logout">ログアウト</button></section><section class="qa-card"><div class="qa-management"><form id="new-seminar"><label>新しいゼミ<input name="title" required maxlength="120" placeholder="例：11月のラボゼミ"></label><button>作成</button></form>${seminars.length?`<label>管理するゼミ<select id="seminar-select">${seminars.map(x=>`<option value="${x.id}" ${x.id===selectedSeminar?'selected':''}>${esc(x.title)}</option>`).join('')}</select></label>`:''}</div>${s?`<div class="qa-session"><div><p class="qa-eyebrow">参加コード</p><strong>${esc(s.join_code)}</strong><a href="${esc(joinUrl(s))}" target="_blank" rel="noopener">${esc(joinUrl(s))}</a></div><canvas id="qr" aria-label="参加用QRコード"></canvas><div class="qa-session-action"><span class="qa-pill">${s.is_open?'質問受付中':'受付停止中'}</span><button id="toggle-open">${s.is_open?'受付を停止':'受付を再開'}</button></div></div>`:'<p>ゼミを作成してください。</p>'}</section>${s?`<section class="qa-card qa-feed"><div class="qa-feed-head"><div><h2>質問一覧</h2><small id="question-count"></small></div>${renderSort()}</div><div id="question-list"></div></section>`:''}<p id="notice" role="status"></p>`);
 document.querySelector<HTMLButtonElement>('#logout')!.onclick=async()=>{await db.auth.signOut();await start();};
 document.querySelector<HTMLFormElement>('#new-seminar')!.onsubmit=async e=>{e.preventDefault();const f=new FormData(e.currentTarget as HTMLFormElement);const {data:{user}}=await db.auth.getUser();const {data,error}=await db.from('seminars').insert({title:String(f.get('title')).trim(),owner_id:user!.id}).select().single();if(error)notice(error.message);else{selectedSeminar=data.id;await loadTeacher();}};
 document.querySelector<HTMLSelectElement>('#seminar-select')?.addEventListener('change',async e=>{selectedSeminar=(e.target as HTMLSelectElement).value;await loadTeacher();});
 document.querySelector<HTMLButtonElement>('#toggle-open')?.addEventListener('click',async()=>{const {error}=await db.from('seminars').update({is_open:!s!.is_open}).eq('id',s!.id);if(error)notice(error.message);else await loadTeacher();});
 const qr=document.querySelector<HTMLCanvasElement>('#qr');if(qr&&s)QRCode.toCanvas(qr,joinUrl(s),{width:150,margin:1});
 wireSort(true);
 document.querySelector<HTMLElement>('#question-list')?.addEventListener('click',async e=>{const button=(e.target as HTMLElement).closest<HTMLButtonElement>('[data-status]');if(!button)return;button.disabled=true;const {error}=await db.rpc('seminar_set_question_status',{p_seminar_id:selectedSeminar,p_question_id:button.dataset.id,p_status:button.dataset.status});if(error){notice(error.message);button.disabled=false;}else await refreshTeacher();});
}
async function refreshTeacher(){
 if(!selectedSeminar)return;
 const {data,error}=await db.rpc('seminar_teacher_feed',{p_seminar_id:selectedSeminar});if(error){notice(error.message);return;}
 teacherItems=data?.questions||[];
 const count=document.querySelector<HTMLElement>('#question-count');if(count)count.textContent=`${teacherItems.filter(q=>q.status!=='hidden').length}件を表示中`;
 renderList(teacherItems,true);
}
async function start(){clearInterval(refreshTimer);if(new URLSearchParams(location.search).has('teacher'))await teacher();else await student();}
start().catch(e=>shell(`<section class="qa-card">${esc(e instanceof Error?e.message:String(e))}</section>`));
