/* ============================================================
   profile.js — KAIWAI 마이페이지 로직
   ------------------------------------------------------------
   · auth.js 에서 만든 전역 Supabase 클라이언트(window.sb) 재사용
   · getSession() 으로 로그인 유저 확인 (없으면 index.html 로)
   · profiles.display_name 이 비어있으면 카이와이 닉네임 생성 → UPDATE
   · 로그인 플랫폼(google/kakao/naver) 뱃지 표시
   · 로그아웃 → signOut → index.html
   ============================================================ */
(() => {
  "use strict";

  const sb = window.sb; // auth.js 가 생성·전역 노출한 클라이언트

  /* ── DOM 참조 ───────────────────────────────────────── */
  const $ = (id) => document.getElementById(id);
  const els = {
    loader:   $("loader"),
    page:     $("page"),
    avatar:   $("avatarImg"),
    nickname: $("nickname"),
    badge:    $("providerBadge"),
    label:    $("providerLabel"),
    grid:     $("feedGrid"),
    empty:    $("emptyHint"),
    logout:   $("logoutBtn"),
    toast:    $("toast"),
  };

  /* ── 1. 카이와이 랜덤 닉네임 생성 ───────────────────────
     수식어 + 명사 + 4자리 숫자(1000~9999) → "말랑말랑마법소녀1234"  */
  const ADJECTIVES = [
    "말랑말랑", "폭신폭신", "딸기맛", "몽글몽글", "반짝반짝",
    "새콤달콤", "보들보들", "말캉말캉", "쫀득쫀득", "두근두근",
    "알록달록", "우유빛", "꿈꾸는", "수줍은", "나른한",
    "멘헤라", "오컬트", "시럽맛", "마시멜로", "청포도맛",
  ];
  const NOUNS = [
    "마법소녀", "쿠로냥", "아기토끼", "솜사탕곰", "천사님",
    "악마짱", "요정", "유령", "인형공주", "별사탕",
    "리본냥", "젤리곰", "막대사탕", "꼬마마녀", "봉제인형",
    "설탕별", "푸딩", "마카롱", "달토끼", "구름양",
  ];
  function generateKawaiiNickname() {
    const adj = ADJECTIVES[Math.floor(Math.random() * ADJECTIVES.length)];
    const noun = NOUNS[Math.floor(Math.random() * NOUNS.length)];
    const num = Math.floor(Math.random() * 9000) + 1000; // 1000~9999
    return `${adj}${noun}${num}`;
  }

  /* ── 2. 디폴트 아바타 (저작권 안전한 귀여운 더미) ───────
     실제 산리오 이미지는 저작권 이슈 → DiceBear 로 유저별 고정 캐릭터 생성  */
  function defaultAvatar(seed) {
    const palette = "ffd6e8,ffc0cb,ffe0ee,fbb1d3";
    return `https://api.dicebear.com/9.x/fun-emoji/svg?seed=${encodeURIComponent(seed)}&backgroundColor=${palette}&radius=50`;
  }

  /* ── 3. 로그인 플랫폼 판별 ──────────────────────────────
     네이버는 Edge Function 이 admin.createUser 로 만들어
     app_metadata.provider 가 'email' → user_metadata.provider='naver' 로 구분.  */
  const PROVIDERS = {
    naver:  { cls: "badge--naver",  ico: "N", label: "네이버" },
    kakao:  { cls: "badge--kakao",  ico: "K", label: "카카오" },
    google: { cls: "badge--google", ico: "G", label: "Google" },
    email:  { cls: "badge--email",  ico: "✉", label: "이메일" },
  };
  function detectProvider(user) {
    if (user?.user_metadata?.provider === "naver") return "naver";
    const p = user?.app_metadata?.provider;
    return PROVIDERS[p] ? p : "email";
  }

  /* ── 4. 더미 피드 그리드 (탭별 6칸) ─────────────────────── */
  const DUMMY = {
    ootd:  ["📸", "👗", "🎀", "🧷", "🩰", "🫧"],
    liked: ["♡", "💖", "🌸", "🍓", "⭐", "🦴"],
  };
  function renderGrid(tab) {
    els.grid.innerHTML = "";
    DUMMY[tab].forEach((ico, i) => {
      const cell = document.createElement("div");
      cell.className = "cell";
      cell.style.animationDelay = `${i * 0.05}s`;
      cell.innerHTML = `<span class="cell__ico">${ico}</span>`;
      els.grid.appendChild(cell);
    });
    els.empty.textContent = tab === "ootd"
      ? "아직 올린 OOTD가 없어요. 첫 코디를 기록해볼까요? ✿"
      : "아직 좋아요 한 코디가 없어요. 마음에 드는 룩을 찾아보세요 ♡";
  }

  /* ── 5. 토스트 ─────────────────────────────────────────── */
  let toastTimer;
  function toast(msg) {
    els.toast.textContent = msg;
    els.toast.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => els.toast.classList.remove("show"), 2600);
  }

  /* ── 6. 렌더링 ─────────────────────────────────────────── */
  function render(user, profile, nickname) {
    els.nickname.textContent = nickname;
    els.avatar.src = profile?.avatar_url || defaultAvatar(user.id);
    els.avatar.onerror = () => { els.avatar.onerror = null; els.avatar.src = defaultAvatar(user.id); };

    const key = detectProvider(user);
    const meta = PROVIDERS[key];
    els.badge.className = `badge ${meta.cls}`;
    els.badge.querySelector(".badge__ico").textContent = meta.ico;
    els.label.textContent = meta.label;
  }

  /* ── 7. 초기화 흐름 ────────────────────────────────────── */
  async function init() {
    if (!sb) { toast("로그인 모듈을 불러오지 못했어요"); return; }

    // (a) 세션 확인
    const { data: { session }, error: sErr } = await sb.auth.getSession();
    if (sErr || !session) { location.replace("index.html"); return; }
    const user = session.user;

    // (b) 프로필 조회 (RLS: 공개 조회 허용)
    const { data: profile, error: pErr } = await sb
      .from("profiles")
      .select("display_name, avatar_url, username")
      .eq("id", user.id)
      .maybeSingle();
    if (pErr) console.warn("프로필 조회 경고:", pErr.message);

    // (c) 닉네임 결정: 있으면 사용, 없으면 생성 후 UPDATE
    //     (profiles 에는 INSERT 정책이 없고 행은 가입 트리거가 이미 생성 → upsert 대신 update)
    let nickname = profile?.display_name?.trim();
    if (!nickname) {
      nickname = generateKawaiiNickname();
      const { error: uErr } = await sb
        .from("profiles")
        .update({ display_name: nickname })
        .eq("id", user.id);
      if (uErr) console.warn("닉네임 저장 경고:", uErr.message);
      else toast(`새 닉네임이 생성됐어요 🎀 ${nickname}`);
    }

    // (d) 화면 그리기
    render(user, profile, nickname);
    renderGrid("ootd");

    // (e) 로딩 → 본문 전환
    els.loader.classList.add("hide");
    els.page.setAttribute("aria-hidden", "false");
    requestAnimationFrame(() => els.page.classList.add("ready"));
  }

  /* ── 8. 이벤트 바인딩 ──────────────────────────────────── */
  // 탭 전환
  document.querySelectorAll(".tab").forEach((btn) => {
    btn.addEventListener("click", () => {
      document.querySelectorAll(".tab").forEach((b) => {
        b.classList.remove("is-active");
        b.setAttribute("aria-selected", "false");
      });
      btn.classList.add("is-active");
      btn.setAttribute("aria-selected", "true");
      renderGrid(btn.dataset.tab);
    });
  });

  // 로그아웃
  els.logout.addEventListener("click", async () => {
    els.logout.disabled = true;
    els.logout.textContent = "로그아웃 중…";
    try {
      await sb.auth.signOut();
    } catch (e) {
      console.warn("signOut 경고:", e?.message || e);
    } finally {
      location.replace("index.html");
    }
  });

  /* ── 시작 ─────────────────────────────────────────────── */
  init().catch((e) => {
    console.error(e);
    toast("문제가 생겼어요. 잠시 후 다시 시도해주세요");
    els.loader.classList.add("hide");
    els.page.setAttribute("aria-hidden", "false");
    els.page.classList.add("ready");
  });
})();
