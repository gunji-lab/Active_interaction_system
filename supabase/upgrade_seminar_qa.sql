-- Add a separate, persistent seminar Q&A board to an existing project.
-- This does not change lecture questions or responses.
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
