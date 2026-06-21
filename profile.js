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

  /* 최고 관리자 화이트리스트 — 계정 UUID 기준
     (소셜 로그인은 이메일이 제공자마다 다르거나 비어있을 수 있어 id 로 식별).
     새 관리자 추가 시 해당 Supabase 계정 id 를 배열에 넣으면 됨. */
  const ADMIN_IDS = [
    '4a612066-9a5d-4da1-905f-fe276fb73908',   // jisulee83@naver.com
    '82feb4b1-5365-4ff9-b68b-ce1b0805a2b2',   // noitaloiv@gmail.com
    '6b2482ab-ddde-46a2-bb71-f26880619fd2',   // rmfjwlak114@gmail.com (운영자)
  ];
  // 이메일 기준 관리자(God Mode) — index.html 의 ADMIN_EMAILS 와 동일하게 유지
  const ADMIN_EMAILS = [
    'jisulee83@naver.com', 'rmfjwlak114@gmail.com', 'admin@kaiwai.kr', 'contact@kaiwai.kr',
    'luffylove04@naver.com',
  ];
  function isAdminUser(user) {
    if (!user) return false;
    if (ADMIN_IDS.includes(user.id)) return true;
    return !!user.email && ADMIN_EMAILS.includes(String(user.email).trim().toLowerCase());
  }
  // 고정 닉네임(이메일별) — 지정 계정은 이 닉네임으로 고정되고 편집 불가
  const FIXED_NICK = {
    'luffylove04@naver.com': 'KAIWAI디자이너',
  };
  function fixedNickFor(user) {
    return (user && user.email) ? (FIXED_NICK[String(user.email).trim().toLowerCase()] || null) : null;
  }

  /* ── DOM 참조 ───────────────────────────────────────── */
  const $ = (id) => document.getElementById(id);
  const els = {
    loader:   $("loader"),
    page:     $("page"),
    avatar:   $("avatarImg"),
    nickname: $("nickname"),
    badge:    $("providerBadge"),
    label:    $("providerLabel"),
    email:    $("userEmail"),
    grid:     $("feedGrid"),
    empty:    $("emptyHint"),
    logout:   $("logoutBtn"),
    toast:    $("toast"),
    // 닉네임 편집
    nickRow:    $("nickRow"),
    editBtn:    $("editNickBtn"),
    nickForm:   $("nickEdit"),
    nickInput:  $("nickInput"),
    nickDice:   $("nickDice"),
    nickSave:   $("nickSave"),
    nickCancel: $("nickCancel"),
  };

  // 현재 로그인 유저 / 닉네임 (편집에서 참조)
  let currentUser = null;
  let currentNick = "";

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

  // 이미 카이와이 닉네임 형식인지(수식어+명사+4자리) 판별 → 재교체 방지(안정 유지)
  function isKawaiiNickname(name) {
    const m = /^(.+?)(\d{4})$/.exec(name || "");
    if (!m) return false;
    const base = m[1];
    return ADJECTIVES.some((a) => base.startsWith(a) && NOUNS.includes(base.slice(a.length)));
  }

  /* 닉네임 중복 검사 — 같은 display_name 을 가진 다른 유저가 있으면 false(중복),
     없으면 true(사용 가능). 본인(excludeId)은 검사에서 제외. */
  async function checkNicknameUnique(name, excludeId) {
    let q = sb.from("profiles").select("id").eq("display_name", name).limit(1);
    if (excludeId) q = q.neq("id", excludeId);
    const { data, error } = await q;
    if (error) { console.warn("닉네임 중복 검사 실패:", error.message); return true; } // 검사 실패 시 통과
    return !data || data.length === 0;
  }

  /* 중복되지 않는 카이와이 닉네임 생성 (최대 10회 재시도 후 충돌 회피 숫자 부가) */
  async function generateUniqueNickname(excludeId) {
    for (let i = 0; i < 10; i++) {
      const cand = generateKawaiiNickname();
      if (await checkNicknameUnique(cand, excludeId)) return cand;
    }
    return generateKawaiiNickname() + Math.floor(Math.random() * 100);
  }

  /* Postgres/PostgREST 에러 → 사용자 친화 메시지 매핑.
     23505=UNIQUE 위반(닉네임 중복 등), 23514=CHECK 위반, 23503=FK 위반.
     매핑되지 않으면 일반 안내 (원문은 콘솔에만). */
  function friendlyDbError(error, fallback = "잠시 후 다시 시도해 주세요.") {
    if (!error) return fallback;
    const code = error.code || "";
    if (code === "23505") return "이미 사용 중이에요. 다른 값을 입력해 주세요.";
    if (code === "23514") return "입력 형식이 올바르지 않아요.";
    if (code === "23503") return "관련 정보를 찾을 수 없어요. 새로고침 후 다시 시도해 주세요.";
    if (code === "42501" || error.status === 403) return "권한이 없어요. 다시 로그인해 주세요.";
    return fallback;
  }

  /* 소셜 로그인 더미 이메일(noreply/users.noreply)은 그대로 노출하지 않고 안내문으로 대체 */
  function displayEmail(email) {
    if (!email) return "이메일 정보 없음";
    return /noreply|users\.noreply/i.test(email) ? "비공개 이메일 (소셜 연동)" : email;
  }

  /* ── 2. 디폴트 아바타 (저작권 안전한 귀여운 더미) ───────
     실제 산리오 이미지는 저작권 이슈 → DiceBear 로 유저별 고정 캐릭터 생성  */
  function defaultAvatar(seed) {
    const palette = "ffd6e8,ffc0cb,ffe0ee,fbb1d3";
    return `https://api.dicebear.com/9.x/fun-emoji/svg?seed=${encodeURIComponent(seed)}&backgroundColor=${palette}&radius=50`;
  }

  /* ── 3. 로그인 플랫폼 판별 ────────────────────────────── */
  const PROVIDERS = {
    kakao:   { cls: "badge--kakao",   ico: "K", label: "카카오 계정" },
    naver:   { cls: "badge--naver",   ico: "N", label: "네이버 계정" },
    google:  { cls: "badge--google",  ico: "G", label: "구글 계정" },
    default: { cls: "badge--default", ico: "♡", label: "KAIWAI 계정" },
  };

  // 현재 세션의 로그인 플랫폼을 정확히 판별. (index.html detectLoginProvider 와 동일 로직)
  // ⚠️ 카카오로 로그인해도 "네이버"로 잘못 뜨던 버그 수정:
  //    user_metadata.provider==="naver" 는 한 번 네이버를 쓴 계정에 영구히 남아,
  //    그 계정으로 카카오 로그인해도 네이버로 폴백되던 것이 원인이었음.
  function detectProvider(user) {
    // ① 가장 최근 로그인 identity = 이번에 쓴 제공자 (병합 계정도 정확)
    const ids = Array.isArray(user?.identities) ? user.identities : [];
    if (ids.length) {
      const latest = ids.reduce((a, b) =>
        new Date(b?.last_sign_in_at || 0) >= new Date(a?.last_sign_in_at || 0) ? b : a
      );
      const p = (latest?.provider || "").toLowerCase();
      if (p === "kakao" || p === "google" || p === "naver") return p;
      // 우리 네이버는 Edge Function(admin.createUser)이라 identity.provider 가 'email'
      if (p === "email" && (user?.user_metadata?.provider || "").toLowerCase() === "naver") return "naver";
    }
    // ② app_metadata.provider 가 소셜이면 그대로 (단일 제공자 계정은 항상 정확)
    const ap = (user?.app_metadata?.provider || "").toLowerCase();
    if (ap === "kakao" || ap === "google" || ap === "naver") return ap;
    // ③ 병합 계정(app_metadata.provider==="email")은 providers 배열로 실제 소셜 보강
    const provs = (user?.app_metadata?.providers || []).map((x) => String(x).toLowerCase());
    if (provs.includes("kakao")  && !provs.includes("naver")) return "kakao";
    if (provs.includes("google") && !provs.includes("naver")) return "google";
    if (provs.includes("naver")) return "naver";
    // ④ 커스텀 네이버 표식 / ⑤ 기본
    if ((user?.user_metadata?.provider || "").toLowerCase() === "naver") return "naver";
    return "default";
  }

  /* ── 4. 피드 그리드 (탭별 실데이터) ─────────────────────────
     내 OOTD = 내가 올린 게시물(author_id=나)
     좋아요 한 코디 = 내가 post_likes 에 누른 게시물
     둘 다 public_feed 뷰에서 이미지 썸네일로 렌더. 피드/업로드 변경이 즉시 반영됨. */
  let _myPosts = null, _likedPosts = null;

  async function loadMyPosts() {
    if (_myPosts) return _myPosts;
    const { data, error } = await sb
      .from("public_feed").select("*")
      .eq("author_id", currentUser.id)
      .order("created_at", { ascending: false });
    if (error) { console.warn("내 OOTD 조회 실패:", error.message); return []; }
    _myPosts = data || [];
    return _myPosts;
  }
  async function loadLikedPosts() {
    if (_likedPosts) return _likedPosts;
    const { data: likes, error: lErr } = await sb
      .from("post_likes").select("post_id").eq("user_id", currentUser.id);
    if (lErr) { console.warn("좋아요 목록 조회 실패:", lErr.message); return []; }
    const ids = (likes || []).map((r) => r.post_id);
    if (!ids.length) { _likedPosts = []; return _likedPosts; }
    const { data, error } = await sb.from("public_feed").select("*").in("id", ids);
    if (error) { console.warn("좋아요 코디 조회 실패:", error.message); return []; }
    _likedPosts = (data || []).sort((a, b) => (b.created_at || "").localeCompare(a.created_at || ""));
    return _likedPosts;
  }
  // 외부(업로드/좋아요 직후)에서 캐시 무효화용
  function invalidateGridCache() { _myPosts = null; _likedPosts = null; }

  function _postCell(p, i) {
    const img = (Array.isArray(p.image_urls) && p.image_urls[0]) || "";
    const cell = document.createElement("div");
    cell.className = "cell" + (img ? " cell--img" : "");
    cell.style.animationDelay = `${i * 0.05}s`;
    cell.style.cursor = "pointer";
    cell.setAttribute("role", "button");
    cell.setAttribute("tabindex", "0");
    cell.setAttribute("aria-label", "피드에서 이 게시물 보기");
    cell.innerHTML = img
      ? `<img src="${img}" alt="OOTD" loading="lazy" style="position:absolute;inset:0;width:100%;height:100%;object-fit:cover"/>`
      : `<span class="cell__ico">🎀</span>`;
    // 클릭 → 피드 탭의 해당 게시물 상세로 이동 (index.html 에서 ?post= 처리)
    const goToPost = () => { location.href = "index.html?post=" + encodeURIComponent(p.id); };
    cell.addEventListener("click", goToPost);
    cell.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); goToPost(); } });
    return cell;
  }

  function _renderSkeleton() {
    els.grid.innerHTML = "";
    for (let i = 0; i < 6; i++) {
      const c = document.createElement("div");
      c.className = "cell";
      c.style.animationDelay = `${i * 0.05}s`;
      els.grid.appendChild(c);
    }
    els.empty.textContent = "";
  }

  async function renderGrid(tab) {
    _renderSkeleton();
    let posts = [];
    try { posts = tab === "ootd" ? await loadMyPosts() : await loadLikedPosts(); }
    catch (e) { console.warn("그리드 로드 실패:", e?.message || e); }
    els.grid.innerHTML = "";
    if (!posts.length) {
      els.empty.textContent = tab === "ootd"
        ? "아직 올린 OOTD가 없어요. 첫 코디를 기록해볼까요? ✿"
        : "아직 좋아요 한 코디가 없어요. 마음에 드는 룩을 찾아보세요 ♡";
      return;
    }
    els.empty.textContent = "";
    posts.forEach((p, i) => els.grid.appendChild(_postCell(p, i)));
  }

  // OOTD 개수 스탯 갱신 (프로필 카드 상단 stats 첫 항목)
  async function updateOotdStat() {
    try {
      const ps = await loadMyPosts();
      const b = document.querySelector(".stats__item b");
      if (b) b.textContent = ps.length;
    } catch (e) { /* 무시 */ }
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
    // 고정 닉네임 계정: 편집(✏️) 버튼 숨김
    if (els.editBtn) els.editBtn.style.display = fixedNickFor(user) ? "none" : "";
    els.avatar.src = profile?.avatar_url || defaultAvatar(user.id);
    els.avatar.onerror = () => { els.avatar.onerror = null; els.avatar.src = defaultAvatar(user.id); };

    const key = detectProvider(user);
    const meta = PROVIDERS[key] || PROVIDERS.default;   // 예외 방어
    els.badge.className = `badge ${meta.cls}`;
    els.badge.querySelector(".badge__ico").textContent = meta.ico;
    els.label.textContent = meta.label;

    // 유저 이메일 (더미 이메일이면 '비공개 이메일'로 대체)
    if (els.email) els.email.textContent = displayEmail(user.email);

    // 보유 포인트 (index.html 과 동일한 localStorage 키 kaiwai_points_<uid>)
    const ptsEl = document.getElementById("profPoints");
    if (ptsEl) {
      let pts = 0;
      try { pts = (JSON.parse(localStorage.getItem("kaiwai_points_" + user.id) || "{}").points) || 0; } catch (_) {}
      ptsEl.textContent = pts.toLocaleString();
    }
  }

  /* ── 6.5 닉네임 인라인 편집 ───────────────────────────── */
  function enterEditMode() {
    if (fixedNickFor(currentUser)) { toast("고정된 닉네임이라 변경할 수 없어요 🎀"); return; }
    els.nickInput.value = currentNick;
    els.nickRow.hidden = true;
    els.nickForm.hidden = false;
    els.nickInput.focus();
    els.nickInput.select();
  }
  function exitEditMode() {
    els.nickForm.hidden = true;
    els.nickRow.hidden = false;
  }
  async function saveNickname() {
    const val = els.nickInput.value.trim();
    if (!val) { toast("닉네임을 입력해주세요"); return; }
    if (val.length > 20) { toast("닉네임은 20자 이하로 입력해주세요"); return; }
    // 관리자 사칭 방지: 금지어 포함 시 차단 (대소문자 무시)
    const BANNED = ["운영","운영자","관리","관리자","admin","master","kaiwai","카이와이"];
    const low = val.toLowerCase();
    if (!isAdminUser(currentUser) && BANNED.some((w) => low.includes(w.toLowerCase()))) {
      toast("관리자 사칭이 우려되는 닉네임은 사용할 수 없어요 🎀");
      return;
    }
    if (val === currentNick) { exitEditMode(); return; }     // 변경 없음

    els.nickSave.disabled = true;
    // 중복 검사 (본인 제외) — 금지어 필터 통과 후
    if (!(await checkNicknameUnique(val, currentUser.id))) {
      els.nickSave.disabled = false;
      toast("이미 다른 천사님이 사용 중인 닉네임이에요 🎀 다른 이름을 지어주세요!");
      return;
    }
    const { data: updated, error } = await sb
      .from("profiles")
      .update({ display_name: val })
      .eq("id", currentUser.id)
      .select("id");                  // 실제로 갱신됐는지(행 존재) 확인
    els.nickSave.disabled = false;

    if (error) {
      console.warn("닉네임 저장 실패:", error.code, error.message);
      // 동시 저장 등으로 인한 UNIQUE 경합은 '중복' 안내로 명확히 매핑
      toast(error.code === "23505"
        ? "이미 다른 천사님이 사용 중인 닉네임이에요 🎀 다른 이름을 지어주세요!"
        : friendlyDbError(error, "저장에 실패했어요. 잠시 후 다시 시도해 주세요."));
      return;
    }
    if (!updated || updated.length === 0) { toast("프로필을 찾을 수 없어요 😢"); return; }

    currentNick = val;
    els.nickname.textContent = val;
    exitEditMode();
    toast("닉네임이 변경됐어요 🎀");
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
    // 고정 닉네임 계정: 지정 닉네임으로 강제 + DB 동기화 (편집 불가)
    const forcedNick = fixedNickFor(user);
    if (forcedNick) {
      nickname = forcedNick;
      if ((profile?.display_name || "") !== forcedNick) {
        const { error: fErr } = await sb.from("profiles").update({ display_name: forcedNick }).eq("id", user.id);
        if (fErr) console.warn("고정 닉네임 저장 경고:", fErr.message);
      }
    }
    // '전부 카이와이로 교체': 카이와이 형식이 아니면(실명/소셜 닉 등) 한 번 교체 후 저장.
    //   카이와이 닉네임은 패턴을 통과 → 이후엔 안 바뀌고 안정적으로 유지됨.
    //   단, 관리자(Admin)·고정닉 계정은 자동 생성/덮어쓰기를 원천 차단.
    if (!forcedNick && !isAdminUser(user) && (!nickname || !isKawaiiNickname(nickname))) {
      nickname = await generateUniqueNickname(user.id);   // 중복 안 되는 닉네임으로
      const { data: updated, error: uErr } = await sb
        .from("profiles")
        .update({ display_name: nickname })
        .eq("id", user.id)
        .select("id");
      if (uErr) {
        console.warn("닉네임 저장 경고:", uErr.message);
      } else if (!updated || updated.length === 0) {
        // 행이 없으면 저장 안 됨 — 가입 트리거 이전에 만들어진 계정일 수 있음
        console.warn("profiles 행이 없어 저장되지 않았어요(가입 트리거 이전 계정 가능성).");
      } else {
        toast(`새 닉네임이 생성됐어요 🎀 ${nickname}`);
      }
    }

    // (d) 화면 그리기
    nickname = nickname || (isAdminUser(user) ? "관리자" : "익명천사");  // 빈 값 방어
    currentUser = user;
    currentNick = nickname;
    render(user, profile, nickname);
    renderGrid("ootd");
    updateOotdStat();

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

  // 닉네임 편집
  els.editBtn.addEventListener("click", enterEditMode);
  els.nickCancel.addEventListener("click", exitEditMode);
  els.nickDice.addEventListener("click", () => {
    els.nickInput.value = generateKawaiiNickname();   // 랜덤 카이와이 닉네임 채우기
    els.nickInput.focus();
  });
  els.nickForm.addEventListener("submit", (e) => { e.preventDefault(); saveNickname(); });
  els.nickInput.addEventListener("keydown", (e) => { if (e.key === "Escape") exitEditMode(); });

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
