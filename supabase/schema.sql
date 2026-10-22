-- For a new project. Existing projects should run upgrade_subquestions.sql instead.
create extension if not exists pgcrypto;

create table if not exists public.lectures (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 120),
  join_code text not null unique default upper(substr(encode(gen_random_bytes(8),'hex'),1,8)),
  active_question_id uuid,
  created_at timestamptz not null default now()
);
create table if not exists public.questions (
  id uuid primary key default gen_random_uuid(),
  lecture_id uuid not null references public.lectures(id) on delete cascade,
  prompt text not null check (char_length(prompt) between 1 and 2000),
  kind text not null check (kind in ('choice','number','text')),
  options jsonb not null default '[]'::jsonb check (jsonb_typeof(options) = 'array' and jsonb_array_length(options) <= 12),
  correct_answer text check (correct_answer is null or char_length(correct_answer) <= 500),
  explanation text check (explanation is null or char_length(explanation) <= 4000),
  parts jsonb not null default '[]'::jsonb check (jsonb_typeof(parts)='array' and jsonb_array_length(parts) between 0 and 12),
  status text not null default 'draft' check (status in ('draft','open','closed','results','explanation')),
  answer_round integer not null default 0,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique (id, lecture_id)
);
alter table public.lectures drop constraint if exists lectures_active_question_fk;
alter table public.lectures add constraint lectures_active_question_fk
  foreign key (active_question_id, id) references public.questions(id, lecture_id) deferrable initially deferred;
create table if not exists public.responses (
  id uuid primary key default gen_random_uuid(),
  question_id uuid not null references public.questions(id) on delete cascade,
  student_token uuid not null,
  answer text not null check (char_length(answer) between 1 and 1000),
  normalized_answer text not null,
  answers jsonb,
  normalized_answers jsonb,
  created_at timestamptz not null default now(),
  unique(question_id, student_token)
);
create index if not exists responses_question_idx on public.responses(question_id);
create index if not exists questions_lecture_idx on public.questions(lecture_id, sort_order);

alter table public.lectures enable row level security;
alter table public.questions enable row level security;
alter table public.responses enable row level security;
revoke all on public.lectures, public.questions, public.responses from anon, authenticated;
grant select, insert, update, delete on public.lectures, public.questions to authenticated;
grant select on public.responses to authenticated;

drop policy if exists lectures_owner on public.lectures;
create policy lectures_owner on public.lectures for all to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));
drop policy if exists questions_owner on public.questions;
create policy questions_owner on public.questions for all to authenticated
  using (exists (select 1 from public.lectures l where l.id = lecture_id and l.owner_id = (select auth.uid())))
  with check (exists (select 1 from public.lectures l where l.id = lecture_id and l.owner_id = (select auth.uid())));
drop policy if exists responses_owner_read on public.responses;
create policy responses_owner_read on public.responses for select to authenticated
  using (exists (select 1 from public.questions q join public.lectures l on l.id=q.lecture_id where q.id=question_id and l.owner_id=(select auth.uid())));

-- Reduce accidental privilege through Supabase's default function grants.
create or replace function public.normalize_number(raw text) returns text
language plpgsql immutable set search_path = '' as $$
declare cleaned text; n numeric;
begin
  cleaned := translate(btrim(raw), '０１２３４５６７８９．－＋，Ｅｅ', '0123456789.-+,Ee');
  cleaned := replace(replace(cleaned, ',', ''), ' ', '');
  if cleaned !~ '^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?$' then return null; end if;
  begin n := cleaned::numeric; exception when numeric_value_out_of_range then return null; end;
  return trim_scale(n)::text;
end $$;
revoke all on function public.normalize_number(text) from public;

create or replace function public.student_view(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  l public.lectures%rowtype; q public.questions%rowtype;
  payload jsonb; effective_parts jsonb; safe_parts jsonb := '[]'::jsonb;
  part jsonb; part_id text; counts jsonb; distribution jsonb := '{}'::jsonb; listed jsonb;
begin
  select * into l from public.lectures where join_code=upper(btrim(p_code));
  if not found then return jsonb_build_object('error','講義が見つかりません'); end if;
  if l.active_question_id is null then return jsonb_build_object('lecture',l.title,'status','waiting'); end if;
  select * into q from public.questions where id=l.active_question_id;
  if not found then return jsonb_build_object('lecture',l.title,'status','waiting'); end if;
  effective_parts := case when jsonb_array_length(q.parts)>0 then q.parts else
    jsonb_build_array(jsonb_build_object('id','main','prompt','','kind',q.kind,'options',q.options,
      'correct_answer',q.correct_answer,'explanation',q.explanation)) end;
  for part in select value from jsonb_array_elements(effective_parts) loop
    safe_parts := safe_parts || jsonb_build_array(
      jsonb_build_object('id',part->>'id','prompt',part->>'prompt','kind',part->>'kind','options',part->'options') ||
      case when q.status='explanation' then jsonb_build_object('correct_answer',part->>'correct_answer','explanation',part->>'explanation') else '{}'::jsonb end);
  end loop;
  payload := jsonb_build_object('lecture',l.title,'question_id',q.id,'answer_round',q.answer_round,'prompt',q.prompt,
    'parts',safe_parts,'status',q.status);
  if q.status in ('results','explanation') then
    for part in select value from jsonb_array_elements(effective_parts) loop
      part_id := part->>'id';
      select coalesce(jsonb_agg(jsonb_build_object('answer',val,'count',n) order by n desc,val),'[]'::jsonb)
        into counts from (
          select coalesce(r.normalized_answers->>part_id,
            case when part_id='main' then r.normalized_answer end) as val, count(*) n
          from public.responses r where r.question_id=q.id group by 1
        ) x where val is not null and val <> '[multiple]';
      distribution := distribution || jsonb_build_object(part_id,counts);
    end loop;
    select coalesce(jsonb_agg(coalesce(r.answers,jsonb_build_object('main',r.answer)) order by r.created_at),'[]'::jsonb)
      into listed from public.responses r where r.question_id=q.id;
    payload := payload || jsonb_build_object('distribution',distribution,'answers',listed);
  end if;
  return payload;
end $$;
revoke all on function public.student_view(text) from public;
grant execute on function public.student_view(text) to anon, authenticated;

-- Retain the old endpoint for a cached copy of the single-question app, but reject multipart questions.
create or replace function public.submit_answer(p_code text,p_question_id uuid,p_token uuid,p_answer text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare q public.questions%rowtype; a text; normalized text;
begin
  select qu.* into q from public.questions qu join public.lectures l on l.id=qu.lecture_id
    where l.join_code=upper(btrim(p_code)) and l.active_question_id=qu.id and qu.id=p_question_id
    for share of qu;
  if not found or q.status <> 'open' then return jsonb_build_object('error','回答受付は終了しています'); end if;
  if jsonb_array_length(q.parts)>0 then return jsonb_build_object('error','画面を再読み込みしてください'); end if;
  a := btrim(p_answer);
  if p_token is null or char_length(a) < 1 or char_length(a) > 1000 then
    return jsonb_build_object('error','回答を確認してください');
  end if;
  if q.kind='choice' then
    if not exists (select 1 from jsonb_array_elements_text(q.options) as opt(value) where opt.value=a) then
      return jsonb_build_object('error','選択肢から回答してください');
    end if;
    normalized := a;
  elsif q.kind='number' then
    normalized := public.normalize_number(a);
    if normalized is null then return jsonb_build_object('error','数値を入力してください'); end if;
  else
    normalized := a;
  end if;
  insert into public.responses(question_id,student_token,answer,normalized_answer)
    values(q.id,p_token,a,normalized) on conflict(question_id,student_token) do nothing;
  return jsonb_build_object('ok',true);
end $$;
revoke all on function public.submit_answer(text,uuid,uuid,text) from public;
grant execute on function public.submit_answer(text,uuid,uuid,text) to anon, authenticated;

create or replace function public.submit_answers(
  p_code text,p_question_id uuid,p_token uuid,p_answers jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  q public.questions%rowtype; effective_parts jsonb; part jsonb;
  part_id text; a text; normalized text; normalized_out jsonb := '{}'::jsonb;
begin
  select qu.* into q from public.questions qu join public.lectures l on l.id=qu.lecture_id
    where l.join_code=upper(btrim(p_code)) and l.active_question_id=qu.id and qu.id=p_question_id
    for share of qu;
  if not found or q.status <> 'open' then return jsonb_build_object('error','回答受付は終了しています'); end if;
  effective_parts := case when jsonb_array_length(q.parts)>0 then q.parts else
    jsonb_build_array(jsonb_build_object('id','main','kind',q.kind,'options',q.options)) end;
  if p_token is null or p_answers is null or jsonb_typeof(p_answers)<>'object' or
    (select count(*) from jsonb_object_keys(p_answers)) <> jsonb_array_length(effective_parts) then
    return jsonb_build_object('error','すべての小問に回答してください');
  end if;
  for part in select value from jsonb_array_elements(effective_parts) loop
    part_id := part->>'id';
    if not p_answers ? part_id or jsonb_typeof(p_answers->part_id)<>'string' then
      return jsonb_build_object('error','すべての小問に回答してください');
    end if;
    a := btrim(p_answers->>part_id);
    if char_length(a) < 1 or char_length(a)>1000 then
      return jsonb_build_object('error','回答を確認してください');
    end if;
    if part->>'kind'='choice' then
      if not exists (select 1 from jsonb_array_elements_text(part->'options') as opt(value) where opt.value=a) then
        return jsonb_build_object('error','選択肢から回答してください');
      end if;
      normalized := a;
    elsif part->>'kind'='number' then
      normalized := public.normalize_number(a);
      if normalized is null then return jsonb_build_object('error','数値を入力してください'); end if;
    elsif part->>'kind'='text' then
      normalized := a;
    else
      return jsonb_build_object('error','問題の形式を確認してください');
    end if;
    normalized_out := normalized_out || jsonb_build_object(part_id,normalized);
  end loop;
  insert into public.responses(question_id,student_token,answer,normalized_answer,answers,normalized_answers)
    values(q.id,p_token,'[multiple]','[multiple]',p_answers,normalized_out)
    on conflict(question_id,student_token) do nothing;
  return jsonb_build_object('ok',true);
end $$;
revoke all on function public.submit_answers(text,uuid,uuid,jsonb) from public;
grant execute on function public.submit_answers(text,uuid,uuid,jsonb) to anon, authenticated;

-- Teacher transitions are checked server-side to prevent opening two questions at once.
create or replace function public.set_question_state(p_lecture_id uuid,p_question_id uuid,p_status text) returns void
language plpgsql security definer set search_path = '' as $$
declare l public.lectures%rowtype;
begin
  select * into l from public.lectures where id=p_lecture_id and owner_id=auth.uid() for update;
  if not found then raise exception '講義へのアクセス権がありません'; end if;
  if p_status not in ('open','closed','results','explanation') then raise exception '無効な状態です'; end if;
  if not exists(select 1 from public.questions where id=p_question_id and lecture_id=p_lecture_id) then raise exception '問題が見つかりません'; end if;
  if p_status='open' then
    update public.questions set status='closed' where id=l.active_question_id and id<>p_question_id and status='open';
    update public.lectures set active_question_id=p_question_id where id=p_lecture_id;
  elsif l.active_question_id is distinct from p_question_id then
    raise exception 'この問題は現在の出題ではありません';
  end if;
  if p_status='results' and (select status from public.questions where id=p_question_id) not in ('closed','results') then
    raise exception '先に受付を終了してください';
  end if;
  if p_status='explanation' and (select status from public.questions where id=p_question_id) not in ('results','explanation') then
    raise exception '先に回答を公開してください';
  end if;
  update public.questions set status=p_status where id=p_question_id;
end $$;
revoke all on function public.set_question_state(uuid,uuid,text) from public;
grant execute on function public.set_question_state(uuid,uuid,text) to authenticated;

-- Return a question to draft, optionally clearing responses for a fresh round.
create or replace function public.reset_question_to_draft(p_lecture_id uuid,p_question_id uuid,p_delete_responses boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare l public.lectures%rowtype; q public.questions%rowtype;
begin
  select * into l from public.lectures where id=p_lecture_id and owner_id=auth.uid() for update;
  if not found then raise exception '講義へのアクセス権がありません'; end if;
  select * into q from public.questions where id=p_question_id and lecture_id=p_lecture_id for update;
  if not found then raise exception '問題が見つかりません'; end if;
  if p_delete_responses is null then raise exception '回答の扱いを選んでください'; end if;
  if p_delete_responses then
    delete from public.responses where question_id=p_question_id;
    update public.questions set answer_round=answer_round+1 where id=p_question_id;
  end if;
  update public.lectures set active_question_id=null where id=p_lecture_id and active_question_id=p_question_id;
  update public.questions set status='draft' where id=p_question_id;
end $$;
revoke all on function public.reset_question_to_draft(uuid,uuid,boolean) from public;
grant execute on function public.reset_question_to_draft(uuid,uuid,boolean) to authenticated;

