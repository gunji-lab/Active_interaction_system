import { createClient } from '@supabase/supabase-js';
import QRCode from 'qrcode';
import './style.css';

const url = import.meta.env.VITE_SUPABASE_URL;
const key = import.meta.env.VITE_SUPABASE_ANON_KEY;
const app = document.querySelector<HTMLDivElement>('#app')!;
if (!url || !key) {
  app.innerHTML = '<main class="card"><h1>初期設定が必要です</h1><p>README に従って Supabase の公開 URL と公開キーを設定してください。</p></main>';
  throw new Error('Missing Supabase public configuration');
}
const db = createClient(url, key);
type Kind = 'choice'|'number'|'text';
type Part = { id:string; prompt:string; kind:Kind; options:string[]; correct_answer:string|null; explanation:string|null };
type Lecture = { id:string; title:string; join_code:string; active_question_id:string|null };
type Question = { id:string; lecture_id:string; prompt:string; kind:Kind; options:string[]; correct_answer:string|null; explanation:string|null; parts:Part[]; status:string; sort_order:number };
type Response = { answer:string; normalized_answer:string; answers:Record<string,string>|null; normalized_answers:Record<string,string>|null; created_at:string };
type Count = { answer:string; count:number };
type StudentView = { error?:string; lecture?:string; status?:string; question_id?:string; answer_round?:number; prompt?:string; parts?:Part[]; distribution?:Record<string,Count[]>; answers?:Record<string,string>[] };
let lectures:Lecture[]=[];
let questions:Question[]=[];
let selectedLecture='';
let selectedQuestion='';
let studentData:StudentView|null=null;
let studentCode='';
let lastView='';
let refreshTimer:number|undefined;
const esc=(s:unknown)=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!));
const message=(s:string)=>{const e=document.querySelector<HTMLElement>('#notice');if(e)e.textContent=s;};
const err=(e:unknown)=>e instanceof Error?e.message:String(e);
const kindName=(k:string)=>({choice:'選択式',number:'数値',text:'自由記述'}[k]||k);
const statusName=(s:string)=>({draft:'準備中',open:'受付中',closed:'受付終了',results:'回答公開中',explanation:'解説公開中',waiting:'出題待ち'}[s]||s);
const blankPart=():Part=>({id:crypto.randomUUID(),prompt:'',kind:'choice',options:[],correct_answer:null,explanation:null});
function questionParts(q:Question):Part[]{return q.parts?.length?q.parts:[{id:'main',prompt:'回答',kind:q.kind,options:q.options,correct_answer:q.correct_answer,explanation:q.explanation}];}
function shell(content:string){app.innerHTML=`<header><a class="brand" href="${location.pathname}">講義レスポンス</a><nav><a href="?teacher=1">教員</a></nav></header><main>${content}</main><footer>匿名回答 • 講義ごとの参加コード</footer>`;}
function codeFromUrl(){return new URLSearchParams(location.search).get('code')?.trim().toUpperCase()||'';}
function studentToken(){let t=localStorage.getItem('lecture-poll-token');if(!t){t=crypto.randomUUID();localStorage.setItem('lecture-poll-token',t);}return t;}
async function start(){clearInterval(refreshTimer);if(new URLSearchParams(location.search).has('teacher'))await teacher();else await student();}
async function student(){
 studentCode=codeFromUrl();
 if(!studentCode){
  shell(`<section class="hero"><p class="eyebrow">学生向け</p><h1>講義に参加</h1><p>先生から共有された参加コードを入力してください。</p><form id="join" class="inline"><input name="code" maxlength="16" required autocomplete="off" placeholder="参加コード"><button>参加する</button></form></section>`);
  document.querySelector<HTMLFormElement>('#join')!.onsubmit=e=>{e.preventDefault();const c=new FormData(e.currentTarget as HTMLFormElement).get('code')?.toString().trim().toUpperCase();if(c)location.href=`?code=${encodeURIComponent(c)}`;};
  return;
 }
 await loadStudent();refreshTimer=window.setInterval(loadStudent,3000);
}
async function loadStudent(){
 const {data,error}=await db.rpc('student_view',{p_code:studentCode});
 if(error){if(!lastView)shell(`<div class="card">接続に失敗しました: ${esc(error.message)}</div>`);return;}
 const d=data as StudentView;const fingerprint=JSON.stringify(d);
 if(fingerprint===lastView)return;
 lastView=fingerprint;studentData=d;renderStudent();
}
function inputForPart(part:Part){
 const name=`answer:${part.id}`;
 if(part.kind==='choice')return (part.options||[]).map(o=>`<label class="option"><input type="radio" name="${esc(name)}" value="${esc(o)}" required><span>${esc(o)}</span></label>`).join('');
 if(part.kind==='number')return `<input name="${esc(name)}" type="text" inputmode="decimal" required maxlength="1000" placeholder="例: 1.5e-3">`;
 return `<textarea name="${esc(name)}" maxlength="1000" required rows="3" placeholder="回答を入力"></textarea>`;
}
function answerList(answers:Record<string,string>[],parts:Part[]){
 return `<ol>${answers.map(a=>`<li>${parts.map((p,i)=>`<strong>問${i+1}:</strong> ${esc(a[p.id]||'—')}`).join('　')}</li>`).join('')}</ol>`;
}
function renderStudent(){
 const d=studentData!;
 if(d.error){shell(`<section class="card"><h1>${esc(d.error)}</h1><a href="${location.pathname}">コードを入力し直す</a></section>`);return;}
 let body='';
 if(d.status==='waiting')body='<div class="card center"><h2>出題を待っています</h2><p>画面は自動更新されます。</p></div>';
 else {
  const parts=d.parts||[];
  const answered=d.question_id&&(localStorage.getItem(`answered:${d.question_id}:${d.answer_round||0}`)==='1'||(!d.answer_round&&localStorage.getItem(`answered:${d.question_id}`)==='1'));
  const accepting=d.status==='open'&&!answered;
  const fields=parts.map((p,i)=>`<fieldset class="student-part"><legend>問${i+1}</legend>${p.prompt?`<h3>${esc(p.prompt)}</h3>`:''}<p class="hint">${esc(kindName(p.kind))}</p>${inputForPart(p)}</fieldset>`).join('');
  body=`<section class="card"><div class="row"><span class="badge">${esc(statusName(d.status||''))}</span><span>${parts.length}問</span></div><h2>${esc(d.prompt)}</h2>${accepting?`<form id="answer-form">${fields}<button class="primary">まとめて回答を送信</button></form>`:d.status==='open'?'<p class="success">回答を送信しました。受付終了までお待ちください。</p>':'<p>回答受付は終了しました。</p>'}<p id="notice" role="status"></p></section>`;
  if(d.status==='results'||d.status==='explanation'){
   body+=`<section class="card"><h2>回答分布 <small>${d.answers?.length||0}件</small></h2>${parts.map((p,i)=>{
    const counts=d.distribution?.[p.id]||[];const total=counts.reduce((n,x)=>n+x.count,0);
    return `<div class="result-part"><h3>問${i+1} ${esc(p.prompt)}</h3>${counts.map(x=>`<div class="bar-row"><span>${esc(x.answer)}</span><div class="bar-track"><i style="width:${total?100*x.count/total:0}%"></i></div><strong>${x.count}</strong></div>`).join('')||'<p>回答はありません。</p>'}</div>`;
   }).join('')}<details><summary>回答一覧を見る</summary>${answerList(d.answers||[],parts)}</details></section>`;
  }
  if(d.status==='explanation')body+=`<section class="card answer"><h2>正解・解説</h2>${parts.map((p,i)=>`<div class="result-part"><h3>問${i+1} ${esc(p.prompt)}</h3><p><strong>正解:</strong> ${esc(p.correct_answer||'未設定')}</p><p class="preline">${esc(p.explanation||'解説はありません。')}</p></div>`).join('')}</section>`;
 }
 shell(`<div class="student-wrap"><p class="eyebrow">${esc(d.lecture)} · ${esc(studentCode)}</p>${body}</div>`);
 const form=document.querySelector<HTMLFormElement>('#answer-form');
 if(form)form.onsubmit=async e=>{
  e.preventDefault();const f=new FormData(form);const answers:Record<string,string>={};
  for(const part of d.parts||[])answers[part.id]=String(f.get(`answer:${part.id}`)||'');
  const button=form.querySelector('button')!;button.disabled=true;
  const {data,error}=await db.rpc('submit_answers',{p_code:studentCode,p_question_id:d.question_id,p_token:studentToken(),p_answers:answers});
  if(error||data?.error){message(error?.message||data.error);button.disabled=false;return;}
  localStorage.setItem(`answered:${d.question_id}:${d.answer_round||0}`,'1');lastView='';await loadStudent();
 };
}
async function teacher(){const {data:{session}}=await db.auth.getSession();if(!session){renderLogin();return;}await loadTeacher();refreshTimer=window.setInterval(refreshTeacher,3000);}
function renderLogin(){
 shell(`<section class="card auth"><p class="eyebrow">教員向け</p><h1>ログイン</h1><form id="login"><label>メールアドレス<input type="email" name="email" required autocomplete="username"></label><label>パスワード<input type="password" name="password" required autocomplete="current-password"></label><button class="primary">ログイン</button></form><p id="notice" role="status"></p></section>`);
 document.querySelector<HTMLFormElement>('#login')!.onsubmit=async e=>{e.preventDefault();const f=new FormData(e.currentTarget as HTMLFormElement);const {error}=await db.auth.signInWithPassword({email:String(f.get('email')),password:String(f.get('password'))});if(error)message(error.message);else await start();};
}
async function loadTeacher(){
 const {data,error}=await db.from('lectures').select('*').order('created_at',{ascending:false});
 if(error){shell(`<section class="card">${esc(error.message)}</section>`);return;}
 lectures=data||[];if(!lectures.some(l=>l.id===selectedLecture))selectedLecture=lectures[0]?.id||'';
 await loadQuestions();renderTeacher();
}
async function loadQuestions(){
 if(!selectedLecture){questions=[];return;}
 const {data,error}=await db.from('questions').select('*').eq('lecture_id',selectedLecture).order('sort_order').order('created_at');
 if(error)throw error;
 questions=data||[];if(!questions.some(q=>q.id===selectedQuestion))selectedQuestion=questions[0]?.id||'';
}
async function refreshTeacher(){
 if(!selectedLecture)return;
 const {data}=await db.from('lectures').select('*').eq('id',selectedLecture).single();
 if(data){const previous=lectures.find(x=>x.id===selectedLecture);if(previous)Object.assign(previous,data);}
 const q=questions.find(x=>x.id===selectedQuestion);
 if(q){const {data:updated}=await db.from('questions').select('*').eq('id',q.id).single();if(updated)Object.assign(q,updated);}
 await renderResponses();
}
function renderTeacher(){
 const l=lectures.find(x=>x.id===selectedLecture);const q=questions.find(x=>x.id===selectedQuestion);
 shell(`<div class="teacher-head"><div><p class="eyebrow">教員向け</p><h1>講義の管理</h1></div><button id="logout" class="ghost">ログアウト</button></div><section class="card"><div class="row"><h2>講義</h2><form id="new-lecture" class="inline"><input name="title" required maxlength="120" placeholder="新しい講義名"><button>作成</button></form></div>${lectures.length?`<select id="lecture-select">${lectures.map(x=>`<option value="${x.id}" ${x.id===selectedLecture?'selected':''}>${esc(x.title)}</option>`).join('')}</select>`:'<p>講義を作成してください。</p>'}${l?`<div class="join-box"><div><span class="eyebrow">参加コード</span><strong>${esc(l.join_code)}</strong><a id="join-link" target="_blank" rel="noopener" href="${esc(joinUrl(l))}">${esc(joinUrl(l))}</a></div><canvas id="qr" aria-label="参加用QRコード"></canvas></div>`:''}</section>${l?`<div class="columns"><section class="card"><div class="row"><h2>問題</h2><button id="new-question" class="ghost">＋ 問題を追加</button></div><div class="question-list">${questions.map(x=>`<button class="question-item ${x.id===selectedQuestion?'selected':''}" data-question="${x.id}"><span>${esc(x.prompt.slice(0,70))}</span><small>${esc(statusName(x.status))}</small></button>`).join('')||'<p>問題はまだありません。</p>'}</div></section><section id="question-panel" class="card">${q?questionPanel(q):'<p>問題を選ぶか、新しく作成してください。</p>'}</section></div>`:''}<p id="notice" role="status"></p>`);
 document.querySelector<HTMLButtonElement>('#logout')!.onclick=async()=>{await db.auth.signOut();await start();};
 document.querySelector<HTMLFormElement>('#new-lecture')!.onsubmit=async e=>{e.preventDefault();const f=new FormData(e.currentTarget as HTMLFormElement);const {data:{user}}=await db.auth.getUser();const {data,error}=await db.from('lectures').insert({title:String(f.get('title')).trim(),owner_id:user!.id}).select().single();if(error)message(error.message);else{selectedLecture=data.id;selectedQuestion='';await loadTeacher();}};
 document.querySelector<HTMLSelectElement>('#lecture-select')?.addEventListener('change',async e=>{selectedLecture=(e.target as HTMLSelectElement).value;selectedQuestion='';await loadTeacher();});
 document.querySelectorAll<HTMLButtonElement>('[data-question]').forEach(b=>b.onclick=async()=>{selectedQuestion=b.dataset.question!;renderTeacher();});
 document.querySelector<HTMLButtonElement>('#new-question')?.addEventListener('click',()=>renderQuestionForm());
 document.querySelector<HTMLButtonElement>('#edit-question')?.addEventListener('click',async()=>{const {count,error}=await db.from('responses').select('id',{count:'exact',head:true}).eq('question_id',q!.id);if(error){message(error.message);return;}if(count){message('回答を残した問題は編集できません。');return;}renderQuestionForm(q);});
 document.querySelectorAll<HTMLButtonElement>('[data-state]:not([data-state="draft"])').forEach(b=>b.onclick=async()=>{b.disabled=true;const {error}=await db.rpc('set_question_state',{p_lecture_id:selectedLecture,p_question_id:selectedQuestion,p_status:b.dataset.state});if(error){message(error.message);b.disabled=false;}else await loadTeacher();});
 document.querySelector<HTMLButtonElement>('[data-state="draft"]')?.addEventListener('click',async()=>{
  const {count,error}=await db.from('responses').select('id',{count:'exact',head:true}).eq('question_id',selectedQuestion);
  if(error){message(error.message);return;}
  if(!count){await resetToDraft(false);return;}
  const dialog=document.querySelector<HTMLDialogElement>('#reset-dialog')!;
  dialog.querySelector<HTMLElement>('[data-response-count]')!.textContent=`${count}件の回答があります。`;
  dialog.showModal();
 });
 document.querySelectorAll<HTMLButtonElement>('[data-reset-delete]').forEach(b=>b.onclick=async()=>{b.disabled=true;await resetToDraft(b.dataset.resetDelete==='true');});
 const qr=document.querySelector<HTMLCanvasElement>('#qr');if(qr&&l)QRCode.toCanvas(qr,joinUrl(l),{width:150,margin:1});
 renderResponses();
}
function joinUrl(l:Lecture){const u=new URL(location.href);u.search=`?code=${encodeURIComponent(l.join_code)}`;return u.href;}
function questionPanel(q:Question){
 const l=lectures.find(x=>x.id===selectedLecture);const parts=questionParts(q);
 return `<div class="row"><span class="badge">${esc(statusName(q.status))}</span>${q.status==='draft'?'<button id="edit-question" class="ghost">編集</button>':''}</div><h2>${esc(q.prompt)}</h2>${parts.map((p,i)=>`<div class="part-summary"><h3>問${i+1} ${esc(p.prompt)}</h3><p>${esc(kindName(p.kind))}</p>${p.kind==='choice'?`<ol>${p.options.map(o=>`<li>${esc(o)}</li>`).join('')}</ol>`:''}</div>`).join('')}<div class="actions">${q.status!=='open'?'<button data-state="open">この問題を出題・受付開始</button>':''}${q.status==='open'?'<button data-state="closed">受付終了</button>':''}${q.status==='closed'?'<button data-state="results">回答分布・一覧を公開</button>':''}${q.status==='results'?'<button data-state="explanation">正解・解説を公開</button>':''}${q.status!=='draft'?'<button data-state="draft" class="ghost">準備中に戻す</button>':''}</div>${l?.active_question_id===q.id?'<p class="hint">この問題が学生画面に表示されています。</p>':'<p class="hint">出題すると学生画面に表示されます。</p>'}<div id="responses"></div>${q.status!=='draft'?'<dialog id="reset-dialog" class="reset-dialog"><form method="dialog"><h3>準備中に戻す</h3><p data-response-count></p><p>回答を残すと問題文は編集できません。回答を削除すると取り消せません。</p><div class="actions"><button type="button" data-reset-delete="false">回答を残して戻す</button><button type="button" data-reset-delete="true" class="danger">回答を削除して戻す</button><button>キャンセル</button></div></form></dialog>':''}`;
}
async function resetToDraft(deleteResponses:boolean){
 const {error}=await db.rpc('reset_question_to_draft',{p_lecture_id:selectedLecture,p_question_id:selectedQuestion,p_delete_responses:deleteResponses});
 if(error){document.querySelector<HTMLDialogElement>('#reset-dialog')?.close();message(error.message);document.querySelectorAll<HTMLButtonElement>('[data-reset-delete]').forEach(b=>b.disabled=false);return;}
 await loadTeacher();
}
function partEditor(p:Part,i:number){
 return `<fieldset class="part-editor" data-part-id="${esc(p.id)}"><legend>問${i+1}</legend><button type="button" class="remove-part ghost" aria-label="問${i+1}を削除">削除</button><label>小問の文<textarea name="part_prompt" rows="2" maxlength="1000" required>${esc(p.prompt)}</textarea></label><label>回答形式<select name="part_kind"><option value="choice" ${p.kind==='choice'?'selected':''}>選択式</option><option value="number" ${p.kind==='number'?'selected':''}>数値</option><option value="text" ${p.kind==='text'?'selected':''}>自由記述</option></select></label><label class="options-wrap" ${p.kind==='choice'?'':'hidden'}>選択肢（1行に1つ、2〜12個）<textarea name="part_options" rows="4">${esc(p.options.join('\n'))}</textarea></label><label>正解（任意）<input name="part_correct" maxlength="500" value="${esc(p.correct_answer||'')}"></label><label>解説（任意）<textarea name="part_explanation" rows="3" maxlength="4000">${esc(p.explanation||'')}</textarea></label></fieldset>`;
}
function renderQuestionForm(q?:Question){
 const panel=document.querySelector<HTMLElement>('#question-panel')!;
 const parts=q?questionParts(q):[blankPart()];
 panel.innerHTML=`<h2>${q?'問題を編集':'新しい問題'}</h2><form id="question-form"><label>大問の文<textarea name="prompt" rows="3" maxlength="2000" required>${esc(q?.prompt||'')}</textarea></label><div id="part-editors">${parts.map(partEditor).join('')}</div><button type="button" id="add-part" class="ghost">＋ 小問を追加</button><div class="actions"><button class="primary">保存</button><button type="button" id="cancel-edit" class="ghost">戻る</button></div></form><p id="form-error" role="alert"></p>`;
 const form=panel.querySelector<HTMLFormElement>('#question-form')!;
 const editors=panel.querySelector<HTMLElement>('#part-editors')!;
 const renumber=()=>editors.querySelectorAll<HTMLFieldSetElement>('.part-editor').forEach((el,i)=>{el.querySelector('legend')!.textContent=`問${i+1}`;});
 form.addEventListener('click',e=>{
  const target=e.target as HTMLElement;
  if(target.closest('#add-part')){
   if(editors.children.length>=12){panel.querySelector<HTMLElement>('#form-error')!.textContent='小問は12問までです。';return;}
   editors.insertAdjacentHTML('beforeend',partEditor(blankPart(),editors.children.length));
  }
  if(target.closest('.remove-part')){
   if(editors.children.length===1){panel.querySelector<HTMLElement>('#form-error')!.textContent='小問を1つ以上残してください。';return;}
   target.closest('.part-editor')?.remove();renumber();
  }
 });
 form.addEventListener('change',e=>{
  const target=e.target as HTMLElement;
  if(target.matches('[name="part_kind"]')){
   const wrap=target.closest('.part-editor')!.querySelector<HTMLElement>('.options-wrap')!;
   wrap.hidden=(target as HTMLSelectElement).value!=='choice';
  }
 });
 panel.querySelector<HTMLButtonElement>('#cancel-edit')!.onclick=()=>renderTeacher();
 form.onsubmit=async e=>{
  e.preventDefault();const f=new FormData(form);const errorBox=panel.querySelector<HTMLElement>('#form-error')!;
  const edited:Part[]=[];
  for(const el of editors.querySelectorAll<HTMLFieldSetElement>('.part-editor')){
   const kind=(el.querySelector<HTMLSelectElement>('[name="part_kind"]')!.value) as Kind;
   const options=el.querySelector<HTMLTextAreaElement>('[name="part_options"]')!.value.split('\n').map(s=>s.trim()).filter(Boolean);
   if(kind==='choice'&&(options.length<2||options.length>12||new Set(options).size!==options.length)){errorBox.textContent='選択肢は重複のない2〜12個を入力してください。';return;}
   edited.push({id:el.dataset.partId!,prompt:el.querySelector<HTMLTextAreaElement>('[name="part_prompt"]')!.value.trim(),kind,options:kind==='choice'?options:[],correct_answer:el.querySelector<HTMLInputElement>('[name="part_correct"]')!.value.trim()||null,explanation:el.querySelector<HTMLTextAreaElement>('[name="part_explanation"]')!.value.trim()||null});
  }
  if(edited.some(p=>!p.prompt)){errorBox.textContent='すべての小問に文を入力してください。';return;}
  const first=edited[0];
  const payload={lecture_id:selectedLecture,prompt:String(f.get('prompt')).trim(),kind:first.kind,options:first.options,correct_answer:first.correct_answer,explanation:first.explanation,parts:edited,sort_order:q?.sort_order??questions.length};
  const result=q?await db.from('questions').update(payload).eq('id',q.id).select().single():await db.from('questions').insert(payload).select().single();
  if(result.error){errorBox.textContent=result.error.message;return;}
  selectedQuestion=result.data.id;await loadTeacher();
 };
}
async function renderResponses(){
 const q=questions.find(x=>x.id===selectedQuestion);const box=document.querySelector<HTMLElement>('#responses');if(!q||!box)return;
 const {data,error}=await db.from('responses').select('answer,normalized_answer,answers,normalized_answers,created_at').eq('question_id',q.id).order('created_at',{ascending:false});
 if(error){box.textContent=error.message;return;}
 const rows=(data||[]) as Response[];const parts=questionParts(q);
 const editButton=document.querySelector<HTMLButtonElement>('#edit-question');
 if(editButton)editButton.hidden=rows.length>0;
 box.innerHTML=`<h3>教員用回答一覧 <small>${rows.length}件</small></h3>${parts.map((p,i)=>{
  const counts=new Map<string,number>();
  rows.forEach(r=>{const value=r.normalized_answers?.[p.id]??(p.id==='main'?r.normalized_answer:undefined);if(value&&value!=='[multiple]')counts.set(value,(counts.get(value)||0)+1);});
  return `<div class="result-part"><h4>問${i+1} ${esc(p.prompt)}</h4><div class="responses">${[...counts].sort((a,b)=>b[1]-a[1]).map(([a,n])=>`<div class="row"><span>${esc(a)}</span><strong>${n}</strong></div>`).join('')||'<p>回答を待っています。</p>'}</div></div>`;
 }).join('')}<details><summary>個別回答を見る</summary><ol>${rows.map(r=>`<li>${parts.map((p,i)=>`<strong>問${i+1}:</strong> ${esc(r.answers?.[p.id]??(p.id==='main'?r.answer:'—'))}`).join('　')} <small>${new Date(r.created_at).toLocaleTimeString('ja-JP')}</small></li>`).join('')}</ol></details>`;
}
start().catch(e=>shell(`<section class="card">${esc(err(e))}</section>`));
