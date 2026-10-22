-- Run this once in SQL Editor for a project that already has the first version installed.
-- Existing questions and responses stay intact.
alter table public.questions add column if not exists parts jsonb not null default '[]'::jsonb;
alter table public.responses add column if not exists answers jsonb;
alter table public.responses add column if not exists normalized_answers jsonb;

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
  payload := jsonb_build_object('lecture',l.title,'question_id',q.id,'prompt',q.prompt,
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
