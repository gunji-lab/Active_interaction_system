import { withSupabase } from 'npm:@supabase/server@1';

type Question = { body: string; status: string; created_at: string; like_count: number };

function slackEscape(value: string): string {
  return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function orderedQuestions(questions: Question[]): Question[] {
  return questions.filter((q) => q.status !== 'hidden')
    .sort((a, b) => b.like_count - a.like_count || Date.parse(b.created_at) - Date.parse(a.created_at));
}

function previewText(title: string, questions: Question[]): string {
  return `${title}｜質問一覧\n${orderedQuestions(questions).map((q) =>
    `• ${q.body.trim().replace(/\r?\n/g, '\n  ')}${q.like_count ? `  （♥ ${q.like_count}）` : ''}`
  ).join('\n')}`;
}

function messageChunks(title: string, questions: Question[]): string[] {
  const ordered = orderedQuestions(questions);
  if (!ordered.length) return [];
  const heading = `*${slackEscape(title)}｜質問一覧*`;
  const chunks: string[] = [];
  let current = heading;
  for (const q of ordered) {
    const body = slackEscape(q.body.trim()).replace(/\r?\n/g, '\n  ');
    const line = `• ${body}${q.like_count ? `  （♥ ${q.like_count}）` : ''}`;
    if (current.length + line.length + 1 > 3500 && current !== heading) {
      chunks.push(current);
      current = `${heading}（続き）`;
    }
    current += `\n${line}`;
  }
  chunks.push(current);
  return chunks;
}

export default {
  fetch: withSupabase({ auth: 'user' }, async (req, ctx) => {
    if (req.method !== 'POST') return Response.json({ error: 'POSTを使ってください' }, { status: 405 });
    let seminarId: string;
    let preview: string;
    try {
      const body = await req.json();
      seminarId = String(body.seminar_id || '');
      preview = String(body.preview || '');
    } catch {
      return Response.json({ error: 'リクエストを確認してください' }, { status: 400 });
    }
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(seminarId)) {
      return Response.json({ error: 'ゼミを選んでください' }, { status: 400 });
    }
    const { data: seminar, error: seminarError } = await ctx.supabase
      .from('seminars').select('id,title,is_open').eq('id', seminarId).single();
    if (seminarError || !seminar) return Response.json({ error: 'ゼミが見つかりません' }, { status: 404 });
    if (seminar.is_open) return Response.json({ error: '先に質問の受付を停止してください' }, { status: 409 });

    const { data: feed, error: feedError } = await ctx.supabase
      .rpc('seminar_teacher_feed', { p_seminar_id: seminarId });
    if (feedError) return Response.json({ error: '質問を読み込めませんでした' }, { status: 500 });
    const questions = (feed?.questions || []) as Question[];
    if (preview !== previewText(seminar.title, questions)) {
      return Response.json({ error: '質問が更新されました。内容を確認してから再送してください' }, { status: 409 });
    }
    const chunks = messageChunks(seminar.title, questions);
    if (!chunks.length) return Response.json({ error: '投稿する質問がありません' }, { status: 400 });

    const webhook = Deno.env.get('SLACK_WEBHOOK_URL');
    if (!webhook || !/^https:\/\/hooks\.slack\.com\/services\//.test(webhook)) {
      return Response.json({ error: 'Slackの送信先が未設定です' }, { status: 500 });
    }
    let sent = 0;
    for (const text of chunks) {
      const response = await fetch(webhook, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text }),
      });
      if (!response.ok) {
        return Response.json({ error: `${sent}件のメッセージを送信した後、Slackへの送信に失敗しました`, sent }, { status: 502 });
      }
      sent++;
      if (sent < chunks.length) await new Promise((resolve) => setTimeout(resolve, 1100));
    }
    return Response.json({ ok: true, messages: sent, questions: questions.filter((q) => q.status !== 'hidden').length });
  }),
};
