// ============================================================
// send-external-notification  —  외부 실시간 알림(Email/SMS·알림톡) 발송 Edge Function
// ------------------------------------------------------------
// 트리거: Supabase Database Webhook (notifications AFTER INSERT) → POST(비동기)
// 흐름:
//   ① x-webhook-secret 검증(웹훅은 JWT 없음 → 시크릿으로 인증)
//   ② payload.record(= notifications 행) 파싱
//   ③ 핵심 알림 타입만 필터(거래 성사/무산/배송 등)
//   ④ service_role 로 수신인 연락처(profiles.phone/notify_*) + 이메일(auth.users) 조회
//   ⑤ Dispatcher: Mock(콘솔) | Live(Resend/Solapi) — DISPATCH_MODE 로 스위칭
//   ⑥ notification_deliveries 멱등 적재(UNIQUE(notification_id, channel) → 중복발송 차단)
//
// Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY(기본 제공),
//          WEBHOOK_SECRET(설정), DISPATCH_MODE('mock'|'live'),
//          (live 시) RESEND_API_KEY, RESEND_FROM, SOLAPI_API_KEY, SOLAPI_API_SECRET, SOLAPI_FROM
// ============================================================
import { createClient } from "jsr:@supabase/supabase-js@2";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { autoRefreshToken: false, persistSession: false } },
);

const MODE = (Deno.env.get("DISPATCH_MODE") ?? "mock").toLowerCase();   // 'mock' | 'live'
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });

// 외부 발송 대상 핵심 알림 타입(거래 성사/무산·배송). 그 외(노이즈)는 인앱만.
const EXTERNAL_TYPES = new Set([
  "bus_ordered",          // 공구 성사(주문 시작)
  "bus_finalized",        // 배송 완료
  "tracking_registered",  // 운송장 등록(=기존 'shipped' 호환)
  "shipped",
  "join_limit_warning",   // 면세 한도 임박 경고
  "paid",                 // 입금 확인(입금 요청 흐름)
  "issue",                // 이슈 발생
]);

// ── 알림 타입별 메시지 템플릿 ──
function buildMessage(rec: any): { subject: string; text: string } {
  const title = rec?.title ?? "KAIWAI 알림";
  const body = rec?.body ?? "";
  return {
    subject: `[KAIWAI] ${title}`,
    text: `${title}\n\n${body}\n\n앱에서 자세히 확인하세요: https://kaiwai-app.vercel.app/`,
  };
}

// ── 어댑터: Mock(콘솔) ──
function mockLog(channel: string) {
  return async (to: string, msg: { subject: string; text: string }) => {
    console.log(
      `\n┌─ [MOCK ${channel.toUpperCase()}] ─────────────────────────\n` +
      `│ to     : ${to}\n` +
      `│ subject: ${msg.subject}\n` +
      `│ body   : ${msg.text.replace(/\n/g, "\n│          ")}\n` +
      `└────────────────────────────────────────────`,
    );
  };
}
// ── 어댑터: Live Resend(Email) — 실제 API 호출 ──
async function sendResend(to: string, msg: { subject: string; text: string }) {
  const key = Deno.env.get("RESEND_API_KEY");
  const from = Deno.env.get("RESEND_FROM") ?? "KAIWAI <noreply@kaiwai.app>";
  if (!key) throw new Error("RESEND_API_KEY 미설정");
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { "Authorization": `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from, to, subject: msg.subject, text: msg.text }),
  });
  if (!r.ok) throw new Error(`Resend ${r.status}: ${await r.text()}`);
}
// ── 어댑터: Live Solapi(SMS) — 실제 API 호출 ──
async function sendSolapi(to: string, msg: { subject: string; text: string }) {
  const key = Deno.env.get("SOLAPI_API_KEY");
  const secret = Deno.env.get("SOLAPI_API_SECRET");
  const from = Deno.env.get("SOLAPI_FROM");
  if (!key || !secret || !from) throw new Error("SOLAPI 키/발신번호 미설정");
  // HMAC 서명(Solapi 표준). 알림톡은 별도 templateId/kakaoOptions 로 확장 가능.
  const date = new Date().toISOString();
  const salt = crypto.randomUUID();
  const sigData = new TextEncoder().encode(date + salt);
  const cryptoKey = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = [...new Uint8Array(await crypto.subtle.sign("HMAC", cryptoKey, sigData))]
    .map((b) => b.toString(16).padStart(2, "0")).join("");
  const auth = `HMAC-SHA256 apiKey=${key}, date=${date}, salt=${salt}, signature=${sig}`;
  const r = await fetch("https://api.solapi.com/messages/v4/send", {
    method: "POST",
    headers: { "Authorization": auth, "Content-Type": "application/json" },
    body: JSON.stringify({ message: { to, from, text: `${msg.subject}\n${msg.text}`.slice(0, 2000) } }),
  });
  if (!r.ok) throw new Error(`Solapi ${r.status}: ${await r.text()}`);
}

const ADAPTERS: Record<string, { live: (t: string, m: any) => Promise<void>; mock: (t: string, m: any) => Promise<void> }> = {
  email: { live: sendResend, mock: mockLog("email") },
  sms: { live: sendSolapi, mock: mockLog("sms") },
};

// ── 채널 1건 발송 + 멱등 로그 ──
async function dispatch(channel: "email" | "sms", to: string, msg: any, rec: any) {
  // 멱등: 같은 (notification_id, channel) 이미 있으면 중복발송 차단
  const { error: claimErr } = await admin.from("notification_deliveries").insert({
    notification_id: rec.id, user_id: rec.user_id, channel, status: "queued",
  });
  if (claimErr) {
    // 23505(unique) = 이미 처리됨 → 스킵
    return { channel, status: "duplicate_skipped" };
  }
  const provider = MODE === "live" ? (channel === "email" ? "resend" : "solapi") : "mock";
  const adapter = ADAPTERS[channel][MODE === "live" ? "live" : "mock"];
  let status = MODE === "live" ? "sent" : "mock";
  let error: string | null = null;
  try {
    await adapter(to, msg);
  } catch (e) {
    status = "failed";
    error = String(e);
  }
  await admin.from("notification_deliveries")
    .update({ status, provider, error })
    .eq("notification_id", rec.id).eq("channel", channel);
  return { channel, status };
}

Deno.serve(async (req) => {
  // ① 웹훅 시크릿 검증
  const secret = Deno.env.get("WEBHOOK_SECRET") ?? "";
  if (!secret || req.headers.get("x-webhook-secret") !== secret) {
    return json({ error: "unauthorized" }, 401);
  }
  try {
    const payload = await req.json().catch(() => ({}));
    const rec = payload?.record ?? payload;   // Supabase webhook: { type, table, record }
    if (!rec?.id || !rec?.user_id) return json({ ok: true, skipped: "no record" });

    // ③ 핵심 타입만 외부 발송
    if (!EXTERNAL_TYPES.has(String(rec.type))) {
      return json({ ok: true, skipped: "non-external type", type: rec.type });
    }

    // ④ 수신인 연락처 + 채널 동의
    const { data: prof } = await admin.from("profiles")
      .select("phone, notify_email, notify_sms").eq("id", rec.user_id).maybeSingle();
    const { data: u } = await admin.auth.admin.getUserById(rec.user_id);
    const email = u?.user?.email ?? null;
    const phone = prof?.phone ?? null;

    const msg = buildMessage(rec);
    const results: any[] = [];

    // ⑤ 동의 + 연락처 있을 때만 발송
    if (prof?.notify_email !== false && email) {
      results.push(await dispatch("email", email, msg, rec));
    } else {
      results.push({ channel: "email", status: "skipped" });
    }
    if (prof?.notify_sms === true && phone) {
      results.push(await dispatch("sms", phone, msg, rec));
    } else {
      results.push({ channel: "sms", status: "skipped" });
    }

    return json({ ok: true, mode: MODE, type: rec.type, results });
  } catch (e) {
    return json({ error: "server error", detail: String(e) }, 500);
  }
});
