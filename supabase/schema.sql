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

-- Separate seminar Q&A board.
create table if not exists public.seminars (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 120),
  join_code text not null unique default upper(substr(encode(gen_random_bytes(8),'hex'),1,8)),
  is_open boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists public.seminar_questions (
  id uuid primary key default gen_random_uuid(),
  seminar_id uuid not null references public.seminars(id) on delete cascade,
  author_name text not null check (char_length(author_name) between 1 and 40),
  body text not null check (char_length(body) between 1 and 1000),
  student_token uuid not null,
  status text not null default 'open' check (status in ('open','answered','hidden')),
  created_at timestamptz not null default now()
);
create table if not exists public.seminar_likes (
  question_id uuid not null references public.seminar_questions(id) on delete cascade,
  student_token uuid not null,
  created_at timestamptz not null default now(),
  primary key (question_id, student_token)
);
create index if not exists seminar_questions_seminar_idx on public.seminar_questions(seminar_id, created_at desc);
create index if not exists seminar_likes_question_idx on public.seminar_likes(question_id);

alter table public.seminars enable row level security;
alter table public.seminar_questions enable row level security;
alter table public.seminar_likes enable row level security;
revoke all on public.seminars, public.seminar_questions, public.seminar_likes from anon, authenticated;
grant select, insert, update on public.seminars to authenticated;
grant select on public.seminar_questions to authenticated;
drop policy if exists seminars_owner on public.seminars;
create policy seminars_owner on public.seminars for all to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
drop policy if exists seminar_questions_owner_read on public.seminar_questions;
create policy seminar_questions_owner_read on public.seminar_questions for select to authenticated
  using (exists (select 1 from public.seminars s where s.id=seminar_id and s.owner_id=(select auth.uid())));

create or replace function public.seminar_feed(p_code text, p_token uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.seminars%rowtype; items jsonb;
begin
  select * into s from public.seminars where join_code=upper(btrim(p_code));
  if not found then return jsonb_build_object('error','ゼミが見つかりません'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',q.id,'body',q.body,'author_name',q.author_name,'status',q.status,
    'created_at',q.created_at,'like_count',(select count(*) from public.seminar_likes l where l.question_id=q.id),
    'liked',exists(select 1 from public.seminar_likes l where l.question_id=q.id and l.student_token=p_token)
  ) order by q.created_at desc),'[]'::jsonb) into items
  from public.seminar_questions q where q.seminar_id=s.id and q.status<>'hidden';
  return jsonb_build_object('title',s.title,'is_open',s.is_open,'questions',items);
end $$;
revoke all on function public.seminar_feed(text,uuid) from public;
grant execute on function public.seminar_feed(text,uuid) to anon, authenticated;

create or replace function public.seminar_post(p_code text,p_token uuid,p_name text,p_body text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.seminars%rowtype; name_clean text; body_clean text; new_id uuid;
begin
  select * into s from public.seminars where join_code=upper(btrim(p_code)) for share;
  if not found then return jsonb_build_object('error','ゼミが見つかりません'); end if;
  if not s.is_open then return jsonb_build_object('error','質問の受付は終了しています'); end if;
  name_clean:=btrim(p_name); body_clean:=btrim(p_body);
  if p_token is null or char_length(name_clean) not between 1 and 40 or char_length(body_clean) not between 1 and 1000 then
    return jsonb_build_object('error','表示名と質問を確認してください');
  end if;
  if (select count(*) from public.seminar_questions where seminar_id=s.id and student_token=p_token)>=30 then
    return jsonb_build_object('error','この端末からの投稿上限に達しました');
  end if;
  insert into public.seminar_questions(seminar_id,student_token,author_name,body)
    values(s.id,p_token,name_clean,body_clean) returning id into new_id;
  return jsonb_build_object('ok',true,'id',new_id);
end $$;
revoke all on function public.seminar_post(text,uuid,text,text) from public;
grant execute on function public.seminar_post(text,uuid,text,text) to anon, authenticated;

create or replace function public.seminar_toggle_like(p_code text,p_question_id uuid,p_token uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare q public.seminar_questions%rowtype;
begin
  if p_token is null then return jsonb_build_object('error','再読み込みしてください'); end if;
  select sq.* into q from public.seminar_questions sq join public.seminars s on s.id=sq.seminar_id
    where s.join_code=upper(btrim(p_code)) and sq.id=p_question_id and sq.status<>'hidden' for share of sq;
  if not found then return jsonb_build_object('error','質問が見つかりません'); end if;
  delete from public.seminar_likes where question_id=q.id and student_token=p_token;
  if found then return jsonb_build_object('liked',false); end if;
  insert into public.seminar_likes(question_id,student_token) values(q.id,p_token)
    on conflict do nothing;
  return jsonb_build_object('liked',true);
end $$;
revoke all on function public.seminar_toggle_like(text,uuid,uuid) from public;
grant execute on function public.seminar_toggle_like(text,uuid,uuid) to anon, authenticated;

create or replace function public.seminar_teacher_feed(p_seminar_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.seminars%rowtype; items jsonb;
begin
  select * into s from public.seminars where id=p_seminar_id and owner_id=auth.uid();
  if not found then raise exception 'ゼミへのアクセス権がありません'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',q.id,'body',q.body,'author_name',q.author_name,'status',q.status,
    'created_at',q.created_at,'like_count',(select count(*) from public.seminar_likes l where l.question_id=q.id)
  ) order by q.created_at desc),'[]'::jsonb) into items
  from public.seminar_questions q where q.seminar_id=s.id;
  return jsonb_build_object('questions',items);
end $$;
revoke all on function public.seminar_teacher_feed(uuid) from public;
grant execute on function public.seminar_teacher_feed(uuid) to authenticated;

create or replace function public.seminar_set_question_status(p_seminar_id uuid,p_question_id uuid,p_status text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_status not in ('open','answered','hidden') then raise exception '無効な状態です'; end if;
  if not exists(select 1 from public.seminars where id=p_seminar_id and owner_id=auth.uid()) then
    raise exception 'ゼミへのアクセス権がありません';
  end if;
  update public.seminar_questions set status=p_status where id=p_question_id and seminar_id=p_seminar_id;
  if not found then raise exception '質問が見つかりません'; end if;
end $$;
revoke all on function public.seminar_set_question_status(uuid,uuid,text) from public;
grant execute on function public.seminar_set_question_status(uuid,uuid,text) to authenticated;

-- Oral-question queue for seminar Q&A.
create table if not exists public.seminar_speakers (
  id uuid primary key default gen_random_uuid(),
  seminar_id uuid not null references public.seminars(id) on delete cascade,
  student_token uuid not null,
  display_name text not null check (char_length(display_name) between 1 and 40),
  status text not null default 'waiting' check (status in ('waiting','done','cancelled')),
  created_at timestamptz not null default now()
);
create unique index if not exists seminar_speakers_one_waiting_idx
  on public.seminar_speakers(seminar_id,student_token) where status='waiting';
create index if not exists seminar_speakers_queue_idx
  on public.seminar_speakers(seminar_id,created_at) where status='waiting';
alter table public.seminar_speakers enable row level security;
revoke all on public.seminar_speakers from anon,authenticated;

create or replace function public.seminar_speaker_toggle(p_code text,p_token uuid,p_name text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.seminars%rowtype; active_id uuid; clean_name text;
begin
  if p_token is null then return jsonb_build_object('error','画面を再読み込みしてください'); end if;
  select * into s from public.seminars where join_code=upper(btrim(p_code)) for update;
  if not found then return jsonb_build_object('error','ゼミが見つかりません'); end if;
  select id into active_id from public.seminar_speakers
    where seminar_id=s.id and student_token=p_token and status='waiting';
  if active_id is not null then
    update public.seminar_speakers set status='cancelled' where id=active_id;
    return jsonb_build_object('waiting',false);
  end if;
  if not s.is_open then return jsonb_build_object('error','口頭質問の受付は終了しています'); end if;
  clean_name:=btrim(p_name);
  if clean_name is null or char_length(clean_name) not between 1 and 40 then
    return jsonb_build_object('error','表示名を入力してください');
  end if;
  insert into public.seminar_speakers(seminar_id,student_token,display_name)
    values(s.id,p_token,clean_name);
  return jsonb_build_object('waiting',true);
end $$;
revoke all on function public.seminar_speaker_toggle(text,uuid,text) from public;
grant execute on function public.seminar_speaker_toggle(text,uuid,text) to anon,authenticated;

create or replace function public.seminar_speaker_done(p_seminar_id uuid,p_speaker_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not exists(select 1 from public.seminars where id=p_seminar_id and owner_id=auth.uid()) then
    raise exception 'ゼミへのアクセス権がありません';
  end if;
  update public.seminar_speakers set status='done'
    where id=p_speaker_id and seminar_id=p_seminar_id and status='waiting';
  if not found then raise exception '希望者が見つかりません'; end if;
end $$;
revoke all on function public.seminar_speaker_done(uuid,uuid) from public;
grant execute on function public.seminar_speaker_done(uuid,uuid) to authenticated;

create or replace function public.seminar_feed(p_code text, p_token uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.seminars%rowtype; items jsonb; speakers jsonb;
begin
  select * into s from public.seminars where join_code=upper(btrim(p_code));
  if not found then return jsonb_build_object('error','ゼミが見つかりません'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',q.id,'body',q.body,'author_name',q.author_name,'status',q.status,
    'created_at',q.created_at,'like_count',(select count(*) from public.seminar_likes l where l.question_id=q.id),
    'liked',exists(select 1 from public.seminar_likes l where l.question_id=q.id and l.student_token=p_token)
  ) order by q.created_at desc),'[]'::jsonb) into items
  from public.seminar_questions q where q.seminar_id=s.id and q.status<>'hidden';
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',sp.id,'name',sp.display_name,'mine',sp.student_token=p_token
  ) order by sp.created_at,sp.id),'[]'::jsonb) into speakers
  from public.seminar_speakers sp where sp.seminar_id=s.id and sp.status='waiting';
  return jsonb_build_object('title',s.title,'is_open',s.is_open,'questions',items,'speakers',speakers);
end $$;
revoke all on function public.seminar_feed(text,uuid) from public;
grant execute on function public.seminar_feed(text,uuid) to anon,authenticated;

create or replace function public.seminar_teacher_feed(p_seminar_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.seminars%rowtype; items jsonb; speakers jsonb;
begin
  select * into s from public.seminars where id=p_seminar_id and owner_id=auth.uid();
  if not found then raise exception 'ゼミへのアクセス権がありません'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',q.id,'body',q.body,'author_name',q.author_name,'status',q.status,
    'created_at',q.created_at,'like_count',(select count(*) from public.seminar_likes l where l.question_id=q.id)
  ) order by q.created_at desc),'[]'::jsonb) into items
  from public.seminar_questions q where q.seminar_id=s.id;
  select coalesce(jsonb_agg(jsonb_build_object('id',sp.id,'name',sp.display_name)
    order by sp.created_at,sp.id),'[]'::jsonb) into speakers
  from public.seminar_speakers sp where sp.seminar_id=s.id and sp.status='waiting';
  return jsonb_build_object('questions',items,'speakers',speakers);
end $$;
revoke all on function public.seminar_teacher_feed(uuid) from public;
grant execute on function public.seminar_teacher_feed(uuid) to authenticated;


-- Answers to seminar questions.
-- Let the seminar owner write an answer on each existing question.
alter table public.seminar_questions
  add column if not exists answer text check (answer is null or char_length(answer) <= 3000);

create or replace function public.seminar_save_answer(p_seminar_id uuid,p_question_id uuid,p_answer text) returns void
language plpgsql security definer set search_path = '' as $$
declare clean_answer text;
begin
  if not exists(select 1 from public.seminars where id=p_seminar_id and owner_id=auth.uid()) then
    raise exception 'ゼミへのアクセス権がありません';
  end if;
  clean_answer:=nullif(btrim(p_answer),'');
  if char_length(clean_answer)>3000 then raise exception '回答は3000文字以内にしてください'; end if;
  update public.seminar_questions set answer=clean_answer
    where id=p_question_id and seminar_id=p_seminar_id;
  if not found then raise exception '質問が見つかりません'; end if;
end $$;
revoke all on function public.seminar_save_answer(uuid,uuid,text) from public;
grant execute on function public.seminar_save_answer(uuid,uuid,text) to authenticated;

create or replace function public.seminar_feed(p_code text, p_token uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.seminars%rowtype; items jsonb; speakers jsonb;
begin
  select * into s from public.seminars where join_code=upper(btrim(p_code));
  if not found then return jsonb_build_object('error','ゼミが見つかりません'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',q.id,'body',q.body,'author_name',q.author_name,'status',q.status,'answer',q.answer,
    'created_at',q.created_at,'like_count',(select count(*) from public.seminar_likes l where l.question_id=q.id),
    'liked',exists(select 1 from public.seminar_likes l where l.question_id=q.id and l.student_token=p_token)
  ) order by q.created_at desc),'[]'::jsonb) into items
  from public.seminar_questions q where q.seminar_id=s.id and q.status<>'hidden';
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',sp.id,'name',sp.display_name,'mine',sp.student_token=p_token
  ) order by sp.created_at,sp.id),'[]'::jsonb) into speakers
  from public.seminar_speakers sp where sp.seminar_id=s.id and sp.status='waiting';
  return jsonb_build_object('title',s.title,'is_open',s.is_open,'questions',items,'speakers',speakers);
end $$;
revoke all on function public.seminar_feed(text,uuid) from public;
grant execute on function public.seminar_feed(text,uuid) to anon,authenticated;

create or replace function public.seminar_teacher_feed(p_seminar_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.seminars%rowtype; items jsonb; speakers jsonb;
begin
  select * into s from public.seminars where id=p_seminar_id and owner_id=auth.uid();
  if not found then raise exception 'ゼミへのアクセス権がありません'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',q.id,'body',q.body,'author_name',q.author_name,'status',q.status,'answer',q.answer,
    'created_at',q.created_at,'like_count',(select count(*) from public.seminar_likes l where l.question_id=q.id)
  ) order by q.created_at desc),'[]'::jsonb) into items
  from public.seminar_questions q where q.seminar_id=s.id;
  select coalesce(jsonb_agg(jsonb_build_object('id',sp.id,'name',sp.display_name)
    order by sp.created_at,sp.id),'[]'::jsonb) into speakers
  from public.seminar_speakers sp where sp.seminar_id=s.id and sp.status='waiting';
  return jsonb_build_object('questions',items,'speakers',speakers);
end $$;
revoke all on function public.seminar_teacher_feed(uuid) from public;
grant execute on function public.seminar_teacher_feed(uuid) to authenticated;

-- Participant comments on seminar questions.
create table if not exists public.seminar_comments (
  id uuid primary key default gen_random_uuid(),
  question_id uuid not null references public.seminar_questions(id) on delete cascade,
  student_token uuid not null,
  author_name text not null check (char_length(author_name) between 1 and 40),
  body text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);
create index if not exists seminar_comments_question_idx on public.seminar_comments(question_id,created_at);
alter table public.seminar_comments enable row level security;
revoke all on public.seminar_comments from anon,authenticated;

create or replace function public.seminar_comment_post(p_code text,p_question_id uuid,p_token uuid,p_name text,p_body text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.seminars%rowtype; clean_name text; clean_body text;
begin
  if p_token is null then return jsonb_build_object('error','画面を再読み込みしてください'); end if;
  select * into s from public.seminars where join_code=upper(btrim(p_code));
  if not found then return jsonb_build_object('error','ゼミが見つかりません'); end if;
  if not s.is_open then return jsonb_build_object('error','コメントの受付は終了しています'); end if;
  if not exists(select 1 from public.seminar_questions where id=p_question_id and seminar_id=s.id and status<>'hidden') then
    return jsonb_build_object('error','質問が見つかりません');
  end if;
  clean_name:=btrim(p_name); clean_body:=btrim(p_body);
  if clean_name is null or char_length(clean_name) not between 1 and 40 then
    return jsonb_build_object('error','表示名を入力してください');
  end if;
  if clean_body is null or char_length(clean_body) not between 1 and 1000 then
    return jsonb_build_object('error','コメントを1〜1000文字で入力してください');
  end if;
  if (select count(*) from public.seminar_comments c join public.seminar_questions q on q.id=c.question_id
      where q.seminar_id=s.id and c.student_token=p_token)>=100 then
    return jsonb_build_object('error','このゼミでのコメント数が上限に達しました');
  end if;
  insert into public.seminar_comments(question_id,student_token,author_name,body)
    values(p_question_id,p_token,clean_name,clean_body);
  return jsonb_build_object('ok',true);
end $$;
revoke all on function public.seminar_comment_post(text,uuid,uuid,text,text) from public;
grant execute on function public.seminar_comment_post(text,uuid,uuid,text,text) to anon,authenticated;

create or replace function public.seminar_feed(p_code text, p_token uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.seminars%rowtype; items jsonb; speakers jsonb;
begin
  select * into s from public.seminars where join_code=upper(btrim(p_code));
  if not found then return jsonb_build_object('error','ゼミが見つかりません'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',q.id,'body',q.body,'author_name',q.author_name,'status',q.status,'answer',q.answer,
    'comments',(select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'author_name',c.author_name,'body',c.body,'created_at',c.created_at) order by c.created_at,c.id),'[]'::jsonb) from public.seminar_comments c where c.question_id=q.id),
    'created_at',q.created_at,'like_count',(select count(*) from public.seminar_likes l where l.question_id=q.id),
    'liked',exists(select 1 from public.seminar_likes l where l.question_id=q.id and l.student_token=p_token)
  ) order by q.created_at desc),'[]'::jsonb) into items
  from public.seminar_questions q where q.seminar_id=s.id and q.status<>'hidden';
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',sp.id,'name',sp.display_name,'mine',sp.student_token=p_token
  ) order by sp.created_at,sp.id),'[]'::jsonb) into speakers
  from public.seminar_speakers sp where sp.seminar_id=s.id and sp.status='waiting';
  return jsonb_build_object('title',s.title,'is_open',s.is_open,'questions',items,'speakers',speakers);
end $$;
revoke all on function public.seminar_feed(text,uuid) from public;
grant execute on function public.seminar_feed(text,uuid) to anon,authenticated;

create or replace function public.seminar_teacher_feed(p_seminar_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.seminars%rowtype; items jsonb; speakers jsonb;
begin
  select * into s from public.seminars where id=p_seminar_id and owner_id=auth.uid();
  if not found then raise exception 'ゼミへのアクセス権がありません'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',q.id,'body',q.body,'author_name',q.author_name,'status',q.status,'answer',q.answer,
    'comments',(select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'author_name',c.author_name,'body',c.body,'created_at',c.created_at) order by c.created_at,c.id),'[]'::jsonb) from public.seminar_comments c where c.question_id=q.id),
    'created_at',q.created_at,'like_count',(select count(*) from public.seminar_likes l where l.question_id=q.id)
  ) order by q.created_at desc),'[]'::jsonb) into items
  from public.seminar_questions q where q.seminar_id=s.id;
  select coalesce(jsonb_agg(jsonb_build_object('id',sp.id,'name',sp.display_name)
    order by sp.created_at,sp.id),'[]'::jsonb) into speakers
  from public.seminar_speakers sp where sp.seminar_id=s.id and sp.status='waiting';
  return jsonb_build_object('questions',items,'speakers',speakers);
end $$;
revoke all on function public.seminar_teacher_feed(uuid) from public;
grant execute on function public.seminar_teacher_feed(uuid) to authenticated;
