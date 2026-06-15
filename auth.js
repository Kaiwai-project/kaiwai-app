/* ============================================================
   auth.js — Supabase 클라이언트 + Naver OAuth(authorization code) 로그인
   ------------------------------------------------------------
   선행 로드 필요 (index.html / callback.html <head>):
     <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
     <script src="auth.js"></script>
   ============================================================ */

/* ── 1. 설정값 (anon key / URL 은 공개되어도 안전) ───────────── */
const SUPABASE_URL = "https://iwrkpwmpfhlyfvutlnuy.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Iml3cmtwd21wZmhseWZ2dXRsbnV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODE0NjMzNDIsImV4cCI6MjA5NzAzOTM0Mn0.8FsCButTXhjftuGjA6v0IbzI3aCUXKykHYmJDV8aI5E";

// Naver 개발자센터에 등록한 값과 동일해야 함
const NAVER_CLIENT_ID = "SFbCj79tPEnzTzc0b2qU";

/* ── 공통 콜백(redirect) URL ──────────────────────────────────
   ⚠️ 이 값은 아래 세 곳에 "글자 하나까지 동일"하게 등록되어야 함:
     1) Naver 개발자센터 → 애플리케이션 → Callback URL
     2) Supabase 대시보드 → Authentication → URL Configuration → Redirect URLs 허용목록
     3) 카카오/구글 콘솔의 Redirect URI (해당 시)
   로컬 개발: 반드시 http 서버로 실행할 것 (file:// 로 열면 origin 이 "null" → 실패).
     예) npx serve  →  http://localhost:3000/auth/callback.html
   배포 시: REDIRECT_URI 를 실제 도메인으로 고정 교체 권장.        */
const REDIRECT_URI = window.location.origin + "/auth/callback.html";
// 로컬 테스트 등 고정값으로 강제하려면 위 줄 대신 아래처럼 직접 지정:
//   const REDIRECT_URI = "http://localhost:3000/auth/callback.html";

// 네이버 인증 페이지로 넘기는 redirect_uri (네이버 콘솔 Callback 과 일치)
const NAVER_REDIRECT_URI = REDIRECT_URI;
// 카카오/구글 등 Supabase 네이티브 OAuth 가 돌아올 곳 (Supabase 허용목록과 일치)
const AUTH_REDIRECT = REDIRECT_URI;

/* ── 2. Supabase 클라이언트 (전역 1개) ──────────────────────── */
//  detectSessionInUrl:false → 콜백에서 수동 코드 교환 (네이버 커스텀 흐름과 충돌 방지)
const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: {
    flowType: "pkce",
    detectSessionInUrl: false,
    persistSession: true,
    autoRefreshToken: true,
  },
});

/* ── 3. CSRF 방지용 state 생성/저장 ─────────────────────────── */
function _makeState() {
  const arr = new Uint8Array(16);
  crypto.getRandomValues(arr);
  const state = Array.from(arr, (b) => b.toString(16).padStart(2, "0")).join("");
  sessionStorage.setItem("naver_oauth_state", state);
  return state;
}

/* ── 4. 로그인 시작: Naver 인증 페이지로 이동 ───────────────── */
function startNaverLogin() {
  const state = _makeState();
  const url =
    "https://nid.naver.com/oauth2.0/authorize?" +
    new URLSearchParams({
      response_type: "code",
      client_id: NAVER_CLIENT_ID,
      redirect_uri: NAVER_REDIRECT_URI,
      state,
    }).toString();
  window.location.href = url;   // 요청하신 location.href 이동
}

/* ── 5. 콜백 처리: code/state → verify-naver → verifyOtp ───── */
//   callback.html 에서 호출. 성공 시 홈으로 리다이렉트.
async function handleNaverCallback() {
  const params = new URLSearchParams(window.location.search);
  const code = params.get("code");
  const state = params.get("state");
  const error = params.get("error");

  if (error) throw new Error("Naver 인증 거부: " + error);
  if (!code || !state) throw new Error("code/state 누락");

  // CSRF 검증: 보냈던 state 와 동일한지 확인
  const saved = sessionStorage.getItem("naver_oauth_state");
  if (!saved || saved !== state) throw new Error("state 불일치 (CSRF 의심)");
  sessionStorage.removeItem("naver_oauth_state");

  // ① Edge Function 호출 (서버에서 token 교환 + 유저 매핑 + token_hash 발급)
  const { data, error: fnErr } = await sb.functions.invoke("verify-naver", {
    body: { code, state },
  });
  if (fnErr) throw new Error("verify-naver 호출 실패: " + fnErr.message);
  if (data?.error) throw new Error(data.error + (data.detail ? " / " + JSON.stringify(data.detail) : ""));

  // ② token_hash 로 세션 확립
  const { error: otpErr } = await sb.auth.verifyOtp({
    token_hash: data.token_hash,   // token_hash 사용 시 email/phone 동봉 금지
    type: "email",
  });
  if (otpErr) throw new Error("세션 확립 실패: " + otpErr.message);

  // ③ 완료 → 홈으로
  return sb.auth.getUser();
}

/* ── 6. 카카오/구글: Supabase 네이티브 OAuth ─────────────────── */
//   signInWithOAuth 가 브라우저를 공급자 → Supabase → AUTH_REDIRECT 로 자동 리다이렉트.
async function startKakaoLogin() {
  const { error } = await sb.auth.signInWithOAuth({
    provider: "kakao",
    options: { redirectTo: AUTH_REDIRECT },
  });
  if (error) throw new Error("카카오 로그인 시작 실패: " + error.message);
}

async function startGoogleLogin() {
  const { error } = await sb.auth.signInWithOAuth({
    provider: "google",
    options: { redirectTo: AUTH_REDIRECT },
  });
  if (error) throw new Error("구글 로그인 시작 실패: " + error.message);
}

/* ── 7. 통합 콜백 핸들러 (callback.html 에서 호출) ───────────── */
//   네이버(커스텀)·카카오·구글(네이티브)을 한 곳에서 처리.
async function handleAuthCallback() {
  const params = new URLSearchParams(window.location.search);
  const code = params.get("code");
  const errorParam = params.get("error") || params.get("error_description");
  if (errorParam) throw new Error("소셜 인증 실패: " + errorParam);
  if (!code) throw new Error("콜백 파라미터(code)가 없습니다.");

  const savedState = sessionStorage.getItem("naver_oauth_state");

  // (a) 네이버 커스텀 흐름: 우리가 저장한 state 와 일치할 때
  if (savedState && params.get("state") === savedState) {
    await handleNaverCallback();        // verify-naver Edge Function + verifyOtp
    return sb.auth.getUser();
  }

  // (b) 카카오/구글: Supabase PKCE 코드 → 세션 교환
  const { error } = await sb.auth.exchangeCodeForSession(code);
  if (error) throw new Error("세션 교환 실패: " + error.message);
  return sb.auth.getUser();
}

/* 전역 노출 (인라인 onclick / callback.html 에서 사용) */
window.sb = sb;
window.startNaverLogin = startNaverLogin;
window.startKakaoLogin = startKakaoLogin;
window.startGoogleLogin = startGoogleLogin;
window.handleNaverCallback = handleNaverCallback;
window.handleAuthCallback = handleAuthCallback;
