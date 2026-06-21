// ============================================================
// verify-host  —  총대 본인인증 + 정산계좌 결합검증 Edge Function
// ------------------------------------------------------------
// 흐름:
//   ① 호출자 Authorization(Bearer access_token) 검증 → 본인 uid 확보
//   ② [외부 제공자] PASS 본인인증 + 1원 계좌인증 → 권위값 획득
//      ※ 현재는 가맹 키 미발급 → "Mock 스텁" 으로 처리.
//        보안 파이프라인(아래 ③④)은 진짜이며, 실제 키 발급 시
//        callPassProvider / callBankProvider 두 함수의 내부만 교체하면 라이브.
//   ③ CI 는 평문 미전송 — Edge Function 에서 sha256(salt‖CI) 해시만 계산해 DB 로 전달
//   ④ finalize_host_verification RPC(service_role) 호출
//        → [결합검증] 예금주명==실명, [1인1총대] CI중복, 기록, verified_host 승격
//          을 DB 트랜잭션에서 강제(Edge Function 버그와 무관하게 DB 가 최종 방어).
//
// Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY(기본 제공), HOST_CI_SALT(설정 필요)
// 클라 호출: sb.functions.invoke("verify-host", { body: { bankName, accountNumber, mockName? } })
// ============================================================
import { createClient } from "jsr:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { autoRefreshToken: false, persistSession: false } },
);

// sha256(salt‖CI) → hex. (CI 원문은 DB 로 절대 보내지 않음)
async function sha256Hex(input: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// ── [외부 제공자 ②] PASS 본인인증 — 실제 키 발급 시 이 함수 내부만 교체 ──
//   반환: { realName, phone, ci }  (ci = 연계정보 원문)
function callPassProvider(uid: string, mockName?: string): { realName: string; phone: string; ci: string } {
  // TODO(실연동): PASS 토큰을 본인확인기관 서버에 시크릿으로 교환 → 권위적 실명/CI 수신.
  // Mock: 사용자별 결정적 값(해피패스). account_holder 와 동일 실명 → 결합검증 통과.
  const realName = (mockName && mockName.trim()) || ("테스트" + uid.slice(0, 4));
  return { realName, phone: "01000000000", ci: "MOCKCI-" + uid };
}
// ── [외부 제공자 ②] 1원 계좌인증 — 실제 키 발급 시 이 함수 내부만 교체 ──
//   반환: { accountHolder }  (은행에 등록된 예금주명)
function callBankProvider(_bankName: string, _accountNumber: string, verifiedRealName: string): { accountHolder: string } {
  // TODO(실연동): 오픈/펌뱅킹 1원 인증 → 은행 권위 예금주명 수신.
  // Mock: 본인 명의 계좌라고 가정 → 예금주명 = 본인인증 실명(결합검증 통과).
  return { accountHolder: verifiedRealName };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
    if (!token) return json({ error: "인증 토큰이 없습니다." }, 401);
    const { data: userData, error: userErr } = await admin.auth.getUser(token);
    if (userErr || !userData?.user) return json({ error: "유효하지 않은 세션입니다." }, 401);
    const uid = userData.user.id;

    const body = await req.json().catch(() => ({}));
    const bankName = String(body?.bankName ?? "").trim();
    const accountNumber = String(body?.accountNumber ?? "").trim();
    if (!bankName || !accountNumber) return json({ error: "은행/계좌번호를 입력해 주세요." }, 400);

    // ② 외부 제공자(Mock) — 권위값 획득
    const pass = callPassProvider(uid, body?.mockName);
    const bank = callBankProvider(bankName, accountNumber, pass.realName);

    // ③ CI 해시 (salt 는 Edge Function 시크릿)
    const salt = Deno.env.get("HOST_CI_SALT") ?? "kaiwai-dev-salt";
    const ciHash = await sha256Hex(salt + "|" + pass.ci);

    // ④ DB 키스톤 RPC — 결합검증/중복/승격을 DB 트랜잭션에서 강제
    const { data, error } = await admin.rpc("finalize_host_verification", {
      p_uid: uid,
      p_real_name: pass.realName,
      p_phone: pass.phone,
      p_ci_hash: ciHash,
      p_bank_name: bankName,
      p_account_number: accountNumber,
      p_account_holder: bank.accountHolder,
      p_provider: "mock",
    });
    if (error) {
      // 결합검증/중복 실패 등 → 사용자 메시지 그대로 전달
      return json({ error: error.message || "본인인증 검증에 실패했습니다." }, 400);
    }
    return json({ ok: true, verified: true });
  } catch (e) {
    return json({ error: "서버 오류", detail: String(e) }, 500);
  }
});
