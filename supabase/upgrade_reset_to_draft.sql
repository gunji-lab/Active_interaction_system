-- Run once in SQL Editor on an existing project. Existing answers are preserved unless you explicitly choose to delete them in the app.
alter table public.questions add column if not exists answer_round integer not null default 0;

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

-- Return an unanswered question to editing mode and remove it from student view.
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

