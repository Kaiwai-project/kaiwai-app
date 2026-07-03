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

/* ── 네이티브(Capacitor) 딥링크 OAuth 설정 ──────────────────────
   웹은 origin + /auth/callback.html 로 복귀하지만, 네이티브 앱은 외부 브라우저가
   http(s)://localhost 로 돌아올 수 없어 '커스텀 스킴 딥링크'로 복귀한다.
   흐름: signInWithOAuth(skipBrowserRedirect) → 인앱브라우저(Browser.open) →
         공급자 로그인 → 커스텀 스킴 리다이렉트 → OS 가 앱 재실행(appUrlOpen) →
         exchangeCodeForSession(code). PKCE code_verifier 는 앱 웹뷰 localStorage 에
         남아 있어(singleTask 로 웹뷰 유지) 교환이 성립한다. */
const CAP = window.Capacitor || null;
const IS_NATIVE = !!(CAP && typeof CAP.isNativePlatform === "function" && CAP.isNativePlatform());
const _capPlugin = (n) => (CAP && CAP.Plugins && CAP.Plugins[n]) || null;

// 커스텀 스킴 딥링크 — AndroidManifest intent-filter + Supabase Redirect 허용목록과 "정확히" 일치.
//   Supabase → Auth → URL Configuration → Redirect URLs 에 아래 값을 반드시 추가할 것.
const NATIVE_REDIRECT = "kr.kaiwai.app://auth/callback";
// 네이버 전용: Naver 콘솔은 http/https 콜백만 허용 → 배포된 브릿지가 커스텀 스킴으로 바운스.
//   ⚠️ 실제 배포 웹 도메인으로 확인/교체하고 Naver 콘솔 Callback + Supabase 허용목록에 등록.
const KAIWAI_WEB_ORIGIN = "https://kaiwai-app.vercel.app";
const NAVER_BRIDGE_URI = KAIWAI_WEB_ORIGIN + "/auth/naver-bridge.html";

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
  // 네이티브: Naver 는 커스텀 스킴을 못 받으므로 https 브릿지로 보낸 뒤 스킴으로 바운스.
  const redirect = IS_NATIVE ? NAVER_BRIDGE_URI : NAVER_REDIRECT_URI;
  const url =
    "https://nid.naver.com/oauth2.0/authorize?" +
    new URLSearchParams({
      response_type: "code",
      client_id: NAVER_CLIENT_ID,
      redirect_uri: redirect,
      state,
    }).toString();
  if (IS_NATIVE) { _openAuthUrl(url); return; }   // 인앱 브라우저로 오픈
  window.location.href = url;   // 웹: 기존 location.href 이동
}

// 인앱 브라우저(Chrome Custom Tab)로 인증 URL 오픈. 플러그인 없으면 웹뷰 내 이동 폴백.
async function _openAuthUrl(url) {
  const Browser = _capPlugin("Browser");
  if (Browser) {
    try { await Browser.open({ url, presentationStyle: "popover" }); return; }
    catch (_) { /* 폴백 */ }
  }
  window.location.href = url;
}

/* ── 5. 콜백 처리: code/state → verify-naver → verifyOtp ───── */
//   callback.html 에서 호출. 성공 시 홈으로 리다이렉트.
// 네이버 코드/스테이트 → 세션 확립 (웹 콜백·네이티브 딥링크 공용 코어)
async function _finishNaver(code, state) {
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

  // ③ 완료
  return sb.auth.getUser();
}

async function handleNaverCallback() {
  const params = new URLSearchParams(window.location.search);
  const code = params.get("code");
  const state = params.get("state");
  const error = params.get("error");

  if (error) throw new Error("Naver 인증 거부: " + error);
  if (!code || !state) throw new Error("code/state 누락");
  return _finishNaver(code, state);
}

/* ── 6. 카카오/구글: Supabase 네이티브 OAuth ─────────────────── */
//   signInWithOAuth 가 브라우저를 공급자 → Supabase → AUTH_REDIRECT 로 자동 리다이렉트.
// 네이티브: Supabase OAuth URL 을 받아(skipBrowserRedirect) 인앱 브라우저로 오픈.
//   공급자→Supabase→커스텀 스킴(NATIVE_REDIRECT) 리다이렉트 → appUrlOpen 이 code 처리.
async function _startOAuthNative(provider) {
  const { data, error } = await sb.auth.signInWithOAuth({
    provider,
    options: { redirectTo: NATIVE_REDIRECT, skipBrowserRedirect: true },
  });
  if (error) throw new Error(provider + " 로그인 시작 실패: " + error.message);
  if (data?.url) await _openAuthUrl(data.url);
}

async function startKakaoLogin() {
  if (IS_NATIVE) return _startOAuthNative("kakao");
  const { error } = await sb.auth.signInWithOAuth({
    provider: "kakao",
    options: { redirectTo: AUTH_REDIRECT },
  });
  if (error) throw new Error("카카오 로그인 시작 실패: " + error.message);
}

async function startGoogleLogin() {
  if (IS_NATIVE) return _startOAuthNative("google");
  const { error } = await sb.auth.signInWithOAuth({
    provider: "google",
    options: { redirectTo: AUTH_REDIRECT },
  });
  if (error) throw new Error("구글 로그인 시작 실패: " + error.message);
}

/* ── 네이티브 딥링크 콜백 핸들러 ────────────────────────────────
   커스텀 스킴(kr.kaiwai.app://auth/callback?...) 으로 앱이 재실행될 때 호출.
   앱 시작 시 initDeepLinkAuth() 로 1회 등록한다. */
let _deepLinkReady = false;
async function _handleDeepLink(url) {
  if (!url || url.indexOf(NATIVE_REDIRECT) !== 0) return;   // 우리 콜백만 처리
  const Browser = _capPlugin("Browser");
  // 스킴 URL 을 표준 URL 로 파싱 (query 는 ? 뒤). URL API 가 커스텀 스킴도 파싱 가능.
  let params;
  try { params = new URL(url).searchParams; }
  catch (_) { params = new URLSearchParams((url.split("?")[1] || "")); }

  const code = params.get("code");
  const state = params.get("state");
  const errParam = params.get("error") || params.get("error_description");
  try {
    if (errParam) throw new Error("소셜 인증 실패: " + errParam);
    if (!code) throw new Error("콜백 파라미터(code)가 없습니다.");

    const savedState = sessionStorage.getItem("naver_oauth_state");
    if (savedState && state === savedState) {
      await _finishNaver(code, state);                 // 네이버(브릿지 경유)
    } else {
      const { error } = await sb.auth.exchangeCodeForSession(code);   // 카카오/구글 PKCE
      if (error) throw new Error("세션 교환 실패: " + error.message);
    }
    if (Browser) { try { await Browser.close(); } catch (_) {} }
    // 세션 확립 → onAuthStateChange 가 앱 UI 를 갱신. 방어적으로 이벤트도 발행.
    window.dispatchEvent(new CustomEvent("kaiwai-auth-success"));
  } catch (e) {
    if (Browser) { try { await Browser.close(); } catch (_) {} }
    window.dispatchEvent(new CustomEvent("kaiwai-auth-error", { detail: String(e.message || e) }));
  }
}

// 앱 시작 시 1회 호출: 딥링크 리스너 등록 + 콜드스타트 URL 처리.
async function initDeepLinkAuth() {
  if (!IS_NATIVE || _deepLinkReady) return;
  const App = _capPlugin("App");
  if (!App) return;
  _deepLinkReady = true;
  App.addListener("appUrlOpen", (data) => { _handleDeepLink(data && data.url); });
  // 앱이 딥링크로 콜드스타트된 경우(launchUrl) 도 처리
  try { const ret = await App.getLaunchUrl(); if (ret && ret.url) _handleDeepLink(ret.url); }
  catch (_) {}
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
window.IS_NATIVE = IS_NATIVE;
window.startNaverLogin = startNaverLogin;
window.startKakaoLogin = startKakaoLogin;
window.startGoogleLogin = startGoogleLogin;
window.handleNaverCallback = handleNaverCallback;
window.handleAuthCallback = handleAuthCallback;
window.initDeepLinkAuth = initDeepLinkAuth;

// 네이티브 앱: 로드 즉시 딥링크 인증 리스너 등록
if (IS_NATIVE) { initDeepLinkAuth(); }
