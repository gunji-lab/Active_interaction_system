-- Add the oral-question queue to an existing seminar Q&A project.
-- Existing seminars, written questions, and likes remain unchanged.
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
