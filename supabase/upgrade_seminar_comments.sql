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
