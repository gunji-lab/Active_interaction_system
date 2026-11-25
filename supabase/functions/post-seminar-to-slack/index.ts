import { withSupabase } from 'npm:@supabase/server@1';

function slackEscape(value: string): string {
  return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function messageChunks(draft: string): string[] {
  const text = slackEscape(draft);
  const chunks: string[] = [];
  let current = '';
  for (const line of text.split('\n')) {
    if (current && current.length + line.length + 1 > 3500) {
      chunks.push(current);
      current = '';
    }
    if (line.length > 3500) {
      if (current) chunks.push(current);
      for (let i = 0; i < line.length; i += 3500) chunks.push(line.slice(i, i + 3500));
      current = '';
    } else {
      current = current ? `${current}\n${line}` : line;
    }
  }
  if (current) chunks.push(current);
  return chunks;
}

export default {
  fetch: withSupabase({ auth: 'user' }, async (req, ctx) => {
    if (req.method !== 'POST') return Response.json({ error: 'POSTを使ってください' }, { status: 405 });
    let seminarId: string;
    let draft: string;
    try {
      const body = await req.json();
      seminarId = String(body.seminar_id || '');
      draft = String(body.draft || '').trim();
    } catch {
      return Response.json({ error: 'リクエストを確認してください' }, { status: 400 });
    }
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(seminarId)) {
      return Response.json({ error: 'ゼミを選んでください' }, { status: 400 });
    }
    if (!draft || draft.length > 12000) {
      return Response.json({ error: '送信する下書きを1〜12000文字で入力してください' }, { status: 400 });
    }
    const { data: seminar, error: seminarError } = await ctx.supabase
      .from('seminars').select('id,is_open').eq('id', seminarId).single();
    if (seminarError || !seminar) return Response.json({ error: 'ゼミが見つかりません' }, { status: 404 });
    if (seminar.is_open) return Response.json({ error: '先に質問の受付を停止してください' }, { status: 409 });

    const { data: feed, error: feedError } = await ctx.supabase
      .rpc('seminar_teacher_feed', { p_seminar_id: seminarId });
    if (feedError) return Response.json({ error: '質問を読み込めませんでした' }, { status: 500 });
    const questionCount = (feed?.questions || []).filter((q: { status: string }) => q.status !== 'hidden').length;
    if (!questionCount) return Response.json({ error: '投稿する質問がありません' }, { status: 400 });

    const chunks = messageChunks(draft);
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
    return Response.json({ ok: true, messages: sent, questions: questionCount });
  }),
};
