// ============================================================
// delete-account  —  회원탈퇴 Edge Function
// ------------------------------------------------------------
// 흐름:
//   ① 호출자의 Authorization(Bearer access_token) 검증 → 본인 uid 확보
//      (다른 사람 계정 삭제 방지 — 토큰 주인만 자기 자신을 삭제)
//   ② Storage 'posts' 버킷의 {uid}/ 폴더 이미지 전부 삭제
//      (DB는 캐스케이드되지만 Storage 객체는 자동 삭제되지 않음)
//   ③ auth.admin.deleteUser(uid)
//      → profiles on delete cascade 로 posts/post_likes/follows/user_favorites 연쇄 삭제
//
// 필요한 Secrets (Edge Function 런타임 기본 제공):
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
//
// 클라이언트 호출:
//   const { data, error } = await sb.functions.invoke("delete-account")
//   (supabase-js 가 현재 세션의 access_token 을 Authorization 헤더로 자동 첨부)
// ============================================================
import { createClient } from "jsr:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

// service_role 키는 Edge Function 내부에서만 사용 (클라이언트 노출 금지)
const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { autoRefreshToken: false, persistSession: false } },
);

// ── {uid}/ 폴더의 Storage 객체 전부 삭제 ────────────────────
async function purgeUserPhotos(uid: string): Promise<void> {
  // posts 버킷에서 본인 폴더(uid/...) 파일 목록 조회 후 일괄 삭제.
  // list 는 폴더 1단계만 반환 — 현재 업로드 경로가 uid/타임스탬프.ext 라 1단계로 충분.
  const { data: files, error: listErr } = await admin.storage
    .from("posts")
    .list(uid, { limit: 1000 });
  if (listErr) {
    console.warn("Storage 목록 조회 경고:", listErr.message);
    return; // 이미지 정리 실패가 계정 삭제를 막지 않도록 (DB 캐스케이드가 본질)
  }
  if (!files || files.length === 0) return;

  const paths = files.map((f) => `${uid}/${f.name}`);
  const { error: rmErr } = await admin.storage.from("posts").remove(paths);
  if (rmErr) console.warn("Storage 삭제 경고:", rmErr.message);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    // ① 호출자 토큰 검증 — Authorization 헤더의 access_token 주인만 자기 계정 삭제 가능
    const authHeader = req.headers.get("Authorization") ?? "";
    const token = authHeader.replace(/^Bearer\s+/i, "").trim();
    if (!token) return json({ error: "인증 토큰이 없습니다." }, 401);

    const { data: userData, error: userErr } = await admin.auth.getUser(token);
    if (userErr || !userData?.user) {
      return json({ error: "유효하지 않은 세션입니다.", detail: userErr?.message }, 401);
    }
    const uid = userData.user.id;

    // ② Storage 본인 이미지 정리 (DB는 ③에서 캐스케이드)
    await purgeUserPhotos(uid);

    // ③ auth.users 삭제 → profiles ON DELETE CASCADE 연쇄
    const { error: delErr } = await admin.auth.admin.deleteUser(uid);
    if (delErr) {
      return json({ error: "계정 삭제 실패", detail: delErr.message }, 500);
    }

    return json({ ok: true });
  } catch (e) {
    return json({ error: "서버 오류", detail: String(e) }, 500);
  }
});
