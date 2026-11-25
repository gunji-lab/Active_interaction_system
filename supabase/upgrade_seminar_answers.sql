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
