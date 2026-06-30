// ============================================================
// verify-host  —  총대 본인인증 + 정산계좌 결합검증 Edge Function
// ------------------------------------------------------------
// 흐름:
//   ① 호출자 Authorization(Bearer access_token) 검증 → 본인 uid 확보
//   ② [외부 제공자] PASS 본인인증 + 계좌 예금주 조회 → 권위값 획득
//      ※ 하이브리드(Mock ↔ Live): PORTONE_API_KEY / PORTONE_API_SECRET /
//        TOSS_SECRET_KEY 시크릿이 모두 설정되고 VERIFICATION_MODE 가 "mock" 이
//        아닐 때만 Live. 하나라도 없으면 자동 Mock 폴백(가맹 키 발급 전 안전).
//        - Live PASS  = PortOne(아임포트) 본인인증 내역 조회 (callPassProviderLive)
//        - Live 계좌  = Toss Payments 예금주 성명조회      (callBankProviderLive)
//   ③ CI 는 평문 미전송 — Edge Function 에서 sha256(salt‖CI) 해시만 계산해 DB 로 전달
//   ④ finalize_host_verification RPC(service_role) 호출
//        → [결합검증] 예금주명==실명, [1인1총대] CI중복, 기록, verified_host 승격
//          을 DB 트랜잭션에서 강제(Edge Function 버그와 무관하게 DB 가 최종 방어).
//
// Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY(기본 제공), HOST_CI_SALT(설정 필요)
//          PORTONE_API_KEY, PORTONE_API_SECRET, TOSS_SECRET_KEY(Live 시 필요),
//          VERIFICATION_MODE(옵션: "mock" 강제, 미설정=키 있으면 live)
// 클라 호출(Mock):  sb.functions.invoke("verify-host", { body: { bankName, accountNumber, mockName? } })
// 클라 호출(Live):  sb.functions.invoke("verify-host", { body: { bankName, accountNumber, impUid } })
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

// ── 은행 이름 정규화 & Toss Payments용 매핑 ──
function mapBankToToss(bankName: string): string {
  const clean = bankName.replace(/\s+/g, "");
  if (clean.includes("국민")) return "국민";
  if (clean.includes("신한")) return "신한";
  if (clean.includes("우리")) return "우리";
  if (clean.includes("하나")) return "하나";
  if (clean.includes("농협")) return "농협";
  if (clean.includes("토스")) return "토스";
  if (clean.includes("카카오")) return "카카오";
  return clean.replace(/은행|뱅크/g, ""); // fallback
}

// ── [외부 제공자] PASS 본인인증 (PortOne) ──
async function callPassProviderLive(impUid: string, impKey: string, impSecret: string): Promise<{ realName: string; phone: string; ci: string }> {
  // 1. 액세스 토큰 획득
  const tokRes = await fetch("https://api.iamport.kr/users/getToken", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ imp_key: impKey, imp_secret: impSecret }),
  });
  if (!tokRes.ok) {
    throw new Error(`PortOne 토큰 요청 실패: ${tokRes.status} ${await tokRes.text()}`);
  }
  const tokData = await tokRes.json();
  if (tokData.code !== 0 || !tokData.response?.access_token) {
    throw new Error(`PortOne 토큰 인증 실패: ${tokData.message || "Unknown error"}`);
  }
  const token = tokData.response.access_token;

  // 2. 인증 정보 조회
  const certRes = await fetch(`https://api.iamport.kr/certifications/${impUid}`, {
    method: "GET",
    headers: { "Authorization": token },
  });
  if (!certRes.ok) {
    throw new Error(`PortOne 본인인증 정보 조회 실패: ${certRes.status} ${await certRes.text()}`);
  }
  const certData = await certRes.json();
  if (certData.code !== 0 || !certData.response) {
    throw new Error(`PortOne 본인인증 내역 조회 실패: ${certData.message || "Unknown error"}`);
  }

  const { name, phone, unique_key } = certData.response;
  if (!name || !unique_key) {
    throw new Error("PortOne 인증 내역에 이름 혹은 실명 식별값(CI)이 없습니다.");
  }
  return { realName: name, phone: phone || "", ci: unique_key };
}

// ── [외부 제공자] 계좌 예금주 성명조회 (Toss Payments) ──
async function callBankProviderLive(bankName: string, accountNumber: string, tossSecretKey: string): Promise<{ accountHolder: string }> {
  const tossBank = mapBankToToss(bankName);
  const basicAuth = btoa(tossSecretKey + ":");

  const res = await fetch("https://api.tosspayments.com/v1/bank-accounts/verify", {
    method: "POST",
    headers: {
      "Authorization": `Basic ${basicAuth}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ bank: tossBank, accountNumber }),
  });
  if (!res.ok) {
    throw new Error(`Toss Payments 예금주 조회 API 오류: ${res.status} ${await res.text()}`);
  }
  const data = await res.json();
  if (!data.holderName) {
    throw new Error("Toss Payments에서 예금주명을 조회하지 못했습니다.");
  }
  return { accountHolder: data.holderName };
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

    // 모드 검사: API 키 세트 유무에 따른 하이브리드(Mock ↔ Live) 처리
    const pKey = Deno.env.get("PORTONE_API_KEY");
    const pSecret = Deno.env.get("PORTONE_API_SECRET");
    const tSecret = Deno.env.get("TOSS_SECRET_KEY");
    const verifMode = Deno.env.get("VERIFICATION_MODE") ?? "live";

    const isMock = !pKey || !pSecret || !tSecret || verifMode === "mock";

    let pass: { realName: string; phone: string; ci: string };
    let bank: { accountHolder: string };
    let provider = "live";

    if (isMock) {
      // Mock 모드 작동 (개발 및 테스트용)
      const mockName = (body?.mockName && String(body.mockName).trim()) || ("테스트" + uid.slice(0, 4));
      pass = { realName: mockName, phone: "01000000000", ci: "MOCKCI-" + uid };
      bank = { accountHolder: mockName };
      provider = "mock";
    } else {
      // Live 모드 작동 (실제 연동)
      const impUid = String(body?.impUid ?? "").trim();
      if (!impUid) return json({ error: "휴대폰 본인인증 정보(impUid)가 누락되었습니다." }, 400);

      pass = await callPassProviderLive(impUid, pKey, pSecret);
      bank = await callBankProviderLive(bankName, accountNumber, tSecret);
    }

    // ③ CI 해시 (salt 는 Edge Function 시크릿)
    const salt = Deno.env.get("HOST_CI_SALT") ?? "kaiwai-dev-salt";
    const ciHash = await sha256Hex(salt + "|" + pass.ci);

    // ④ DB 키스톤 RPC — 결합검증/중복/승격을 DB 트랜잭션에서 강제
    const { error } = await admin.rpc("finalize_host_verification", {
      p_uid: uid,
      p_real_name: pass.realName,
      p_phone: pass.phone,
      p_ci_hash: ciHash,
      p_bank_name: bankName,
      p_account_number: accountNumber,
      p_account_holder: bank.accountHolder,
      p_provider: provider,
    });
    if (error) {
      return json({ error: error.message || "본인인증 검증에 실패했습니다." }, 400);
    }
    return json({ ok: true, verified: true });
  } catch (e) {
    return json({ error: "서버 오류", detail: String(e) }, 500);
  }
});
