/* ════════════════════════════════════════════════════════════════
   KAIWAI 공구(Co-op) 코어 — 순수 비즈니스 로직 (UI/DOM 비의존)
   · 상태값 관리(State Machine), 데이터 무결성, 쿨다운, 무산/환불/페널티만 담당.
   · 모든 함수: 성공 시 true 또는 데이터 반환 / 실패 시 구체적 Error throw.
   · document·window·alert 등 UI API 일절 사용하지 않음. (Node/브라우저 공용)
   사용:  const sys = CoopCore.createCoopSystem(coop, users); sys.joinCoop(uid, 300);
   ════════════════════════════════════════════════════════════════ */
(function (global) {
  "use strict";

  /* ── 상수 ── */
  const ADMIN_EMAILS = [
    "jisulee83@naver.com",
    "rmfjwlak114@gmail.com",
    "admin@kaiwai.kr",
    "contact@kaiwai.kr",
    "luffylove04@naver.com",
  ];
  const DEPOSIT = 300;                         // 탑승 보증금(P)
  const PROBLEM_COOLDOWN_MS = 60 * 60 * 1000;  // 문제 발생 알림 쿨다운 60분
  const NOSHOW_COOLDOWN_MS  = 10 * 60 * 1000;  // 노쇼 경고 알림 쿨다운 10분
  const REFUND_DEADLINE_MS  = 24 * 60 * 60 * 1000; // 환불 증빙 마감 24시간
  const MAX_CANCELS = 3;                        // 누적 무산 N회 이상 → 총대 자격 정지
  const HOST_FAULT_PENALTY = 20;               // 귀책 무산 시 신뢰점수 차감폭

  // 상태값은 DB(buses.status enum) / docs/coop_lifecycle_decision.md 와 통일.
  //   recruiting → closed → completed  /  recruiting|closed → canceled  /  recruiting → expired
  //   (내부 참조 키 ORDER_STARTED/CANCELLED/DONE 는 하위호환 위해 보존, 값만 표준화 + 별칭 추가)
  const COOP_STATUS = Object.freeze({
    RECRUITING: "recruiting",     // 모집 중
    ORDER_STARTED: "closed",      // 마감/출발(정보 잠금)
    CANCELLED: "canceled",        // 취소
    DONE: "completed",            // 수령완료
    EXPIRED: "expired",           // 기한 만료(미달)
    // 스펙 표준 별칭
    CLOSED: "closed",
    CANCELED: "canceled",
    COMPLETED: "completed",
  });
  const RIDER_STATUS = Object.freeze({
    JOINED: "joined",
    PAID: "paid",
    ISSUE: "problem-processing",
    NOSHOW: "warning-noshow",
  });
  const REFUND_STATUS = Object.freeze({
    NONE: null,
    PENDING: "refund-pending",       // 환불 대기 중
    COMPLETED: "refund-completed",   // 환불 완료(파티원 확인)
  });
  const FAULT = Object.freeze({ HOST: "host", FORCE_MAJEURE: "force-majeure" });

  /* ── 순수 판정 ── */
  function checkAdmin(email) {
    if (!email) return false;
    return ADMIN_EMAILS.indexOf(String(email).trim().toLowerCase()) !== -1;
  }

  /* ── 팩토리 ── */
  function createUserProfile(id, email) {
    if (!id) throw new Error("userId는 필수입니다.");
    return {
      id: id,
      email: email || "",
      points: 0,
      isAdmin: checkAdmin(email),
      trustScore: 100,     // 총대 신뢰 점수(0~100)
      cancelCount: 0,      // 귀책 무산 누적
      hostSuspended: false,
    };
  }

  function createCoop(opts) {
    opts = opts || {};
    if (!opts.id) throw new Error("coop.id는 필수입니다.");
    if (!opts.hostId) throw new Error("coop.hostId는 필수입니다.");
    const goal = parseInt(opts.goalYen, 10);
    if (!goal || goal < 1) throw new Error("목표 금액(엔)은 1 이상이어야 합니다.");
    return {
      id: opts.id,
      hostId: opts.hostId,
      goalYen: goal,
      status: COOP_STATUS.RECRUITING,
      isOrderStarted: false,
      riders: [],
      cancelReason: null,
      cancelFault: null,
      cancelledAt: null,
      refundRequestedAt: null,
      refundProofUrl: null,
      createdAt: Date.now(),
    };
  }

  /* ════════════════════════════════════════════════════════════════
     상품 URL 파싱 — CORS 우회(allorigins 프록시) + DOMParser
     fetchProductDataFromUrl(url) → { title, imageUrl, price } / 실패 시 throw
     ════════════════════════════════════════════════════════════════ */
  const PROXY_BASE = "https://api.allorigins.win/get?url=";

  // og:description·메타·본문에서 가격(정수) 추출 시도. 실패 시 0.
  function extractPrice(doc, ogDescription) {
    function toInt(s) {
      const n = parseInt(String(s == null ? "" : s).replace(/[,\.\s]/g, ""), 10);
      return isNaN(n) || n <= 0 ? 0 : n;
    }
    // 1) 가격 전용 메타 우선
    const priceMetaSels = [
      'meta[property="product:price:amount"]',
      'meta[property="og:price:amount"]',
      'meta[itemprop="price"]',
    ];
    for (let i = 0; i < priceMetaSels.length; i++) {
      const el = doc.querySelector(priceMetaSels[i]);
      if (el) { const p = toInt(el.getAttribute("content")); if (p) return p; }
    }
    // 2) 통화기호/단위 주변 숫자 (¥ ₩ $ 円 원 엔 JPY KRW)
    const re = /(?:[¥₩$]|円|원|엔|JPY|KRW)\s*([0-9][0-9,\.]{1,})|([0-9][0-9,\.]{1,})\s*(?:円|원|엔|JPY|KRW)/i;
    const bodyText = (doc.body && doc.body.textContent) || "";
    const sources = [ogDescription || "", bodyText];
    for (let i = 0; i < sources.length; i++) {
      const m = re.exec(sources[i]);
      if (m) { const p = toInt(m[1] || m[2]); if (p) return p; }
    }
    return 0;
  }

  // HTML 문자열 → 상품 정보 (DOMParser 필요). fetch 와 분리해 단위 테스트 용이.
  // 가져오기 실패/차단/정보 없음 시 안전 기본값
  const PRODUCT_FALLBACK_TITLE = "정보를 불러올 수 없습니다";
  function _productFallback(reason) {
    return { title: PRODUCT_FALLBACK_TITLE, imageUrl: "", price: 0, ok: false, reason: reason || "unknown" };
  }

  // URL 형식 사전 검증 (이상 텍스트 차단). 유효하면 정규화된 URL 문자열, 아니면 null.
  function validateUrl(url) {
    const s = String(url == null ? "" : url).trim();
    // http/https + 점 있는 호스트 + 공백 없음
    if (!/^https?:\/\/[^\s/$.?#][^\s]*\.[^\s]+$/i.test(s)) return null;
    if (typeof URL === "function") {
      try { const u = new URL(s); if (u.protocol !== "http:" && u.protocol !== "https:") return null; return u.href; }
      catch (e) { return null; }
    }
    return s;
  }

  function parseProductHtml(html) {
    if (!html || typeof html !== "string") return _productFallback("empty-html");
    if (typeof DOMParser === "undefined") return _productFallback("no-domparser");
    let doc;
    try { doc = new DOMParser().parseFromString(html, "text/html"); }
    catch (e) { return _productFallback("parse-error"); }
    function meta(prop) {
      const el = doc.querySelector('meta[property="' + prop + '"]') || doc.querySelector('meta[name="' + prop + '"]');
      return el ? (el.getAttribute("content") || "").trim() : "";
    }
    // 상품명: og:title → twitter:title → <title>
    const titleEl = doc.querySelector("title");
    const title = meta("og:title") || meta("twitter:title") || (titleEl ? (titleEl.textContent || "").trim() : "");
    // 이미지: og:image → twitter:image → 본문 첫 유효 <img>(data/svg/1px 제외)
    let imageUrl = meta("og:image") || meta("twitter:image") || "";
    if (!imageUrl) {
      const imgs = doc.querySelectorAll("img");
      for (let i = 0; i < imgs.length; i++) {
        const s = (imgs[i].getAttribute("src") || imgs[i].getAttribute("data-src") || "").trim();
        if (s && !/^data:/i.test(s) && !/\.svg(\?|$)/i.test(s) && !/1x1|spacer|blank/i.test(s)) { imageUrl = s; break; }
      }
    }
    // 제목·이미지 둘 다 없으면(차단/봇 페이지 등) 안전 기본값 반환
    if (!title && !imageUrl) return _productFallback("no-og-tags");
    return {
      title: title || PRODUCT_FALLBACK_TITLE,
      imageUrl: imageUrl,
      price: extractPrice(doc, meta("og:description")),
      ok: !!(title || imageUrl),
    };
  }

  /* 상품 정보 추출 — 잘못된 URL 만 throw(사전 차단), 그 외(차단/네트워크/og없음)는 안전 폴백 반환 */
  async function fetchProductDataFromUrl(url) {
    const target = validateUrl(url);
    if (!target) throw new Error("올바른 상품 URL 형식이 아닙니다. (http/https 주소를 입력하세요)");
    if (typeof fetch === "undefined") return _productFallback("no-fetch");
    try {
      const res = await fetch(PROXY_BASE + encodeURIComponent(target));
      if (!res.ok) return _productFallback("http-" + res.status);
      const payload = await res.json();
      const html = payload && payload.contents;
      if (!html) return _productFallback("no-contents");
      return parseProductHtml(html);   // { title, imageUrl, price, ok }
    } catch (e) {
      return _productFallback("network-error");   // 차단/타임아웃/JSON오류 등 → 안전 폴백
    }
  }

  /* ── 시스템(컨텍스트): 유저 레지스트리 + 하나의 공구 ──
     users 는 Map / 배열 / {id:profile} 무엇이든 흡수. */
  function createCoopSystem(coop, users, opts) {
    if (!coop) throw new Error("coop이 필요합니다.");
    opts = opts || {};
    const now = typeof opts.now === "function" ? opts.now : function () { return Date.now(); };

    const _users = new Map();
    if (users instanceof Map) {
      users.forEach(function (v, k) { _users.set(k, v); });
    } else if (Array.isArray(users)) {
      users.forEach(function (u) { _users.set(u.id, u); });
    } else if (users && typeof users === "object") {
      Object.keys(users).forEach(function (k) { _users.set(users[k].id || k, users[k]); });
    }

    function _user(uid) {
      const u = _users.get(uid);
      if (!u) throw new Error("존재하지 않는 유저입니다: " + uid);
      return u;
    }
    function _rider(uid) { return coop.riders.find(function (r) { return r.userId === uid; }); }
    function _requireHostOrAdmin(actorId) {
      const a = _user(actorId);
      if (actorId !== coop.hostId && !a.isAdmin) {
        throw new Error("방장 또는 관리자만 수행할 수 있는 작업입니다.");
      }
      return a;
    }

    const api = {
      coop: coop,
      users: _users,
      checkAdmin: checkAdmin,
      addUser: function (u) { if (!u || !u.id) throw new Error("유저 객체가 올바르지 않습니다."); _users.set(u.id, u); return true; },
      getRider: function (uid) { return _rider(uid) || null; },

      /* 탑승: 300P 차감 로직은 DB(Supabase) 서버 사이드로 완전 이관됨.
         순수 코어에서는 상태 변경(라이더 추가)만 담당. */
      joinCoop: function (userId, deposit) {
        const dep = (deposit == null) ? DEPOSIT : deposit;
        _user(userId); // 존재 검증 가드(없는 유저면 throw) — 반환값은 사용 안 함
        if (coop.status !== COOP_STATUS.RECRUITING) throw new Error("모집 중인 공구만 탑승할 수 있습니다.");
        if (coop.isOrderStarted) throw new Error("이미 주문이 시작되어 탑승할 수 없습니다.");
        if (userId === coop.hostId) throw new Error("방장은 자신의 공구에 탑승할 수 없습니다.");
        if (_rider(userId)) throw new Error("이미 탑승한 유저입니다.");
        
        // 포인트 부족 예외 및 차감 로직 삭제됨 (RPC가 담당)
        coop.riders.push({
          userId: userId,
          deposit: dep,
          status: RIDER_STATUS.JOINED,
          paid: false,
          courierName: null, trackingNumber: null,
          issueAt: 0, noshowAt: 0, issueReason: null,
          refundStatus: REFUND_STATUS.NONE,
          joinedAt: now(),
        });
        return true;
      },

      /* 주문 시작 → 전체 Lock (isOrderStarted = true) */
      startOrder: function (adminId) {
        _requireHostOrAdmin(adminId);
        if (coop.status === COOP_STATUS.CANCELLED) throw new Error("무산된 공구는 주문을 시작할 수 없습니다.");
        if (coop.isOrderStarted) throw new Error("이미 주문이 시작되었습니다.");
        if (coop.riders.length === 0) throw new Error("탑승자가 없어 주문을 시작할 수 없습니다.");
        coop.isOrderStarted = true;
        coop.status = COOP_STATUS.ORDER_STARTED;
        return true;
      },

      /* 입금 승인 */
      approvePay: function (adminId, userId) {
        _requireHostOrAdmin(adminId);
        const r = _rider(userId);
        if (!r) throw new Error("탑승자가 아닙니다.");
        if (r.paid) throw new Error("이미 입금 완료 처리된 유저입니다.");
        r.paid = true;
        r.status = RIDER_STATUS.PAID;
        return true;
      },

      /* 문제 발생 — 60분 쿨다운 계산 */
      raiseIssue: function (userId, reason) {
        const r = _rider(userId);
        if (!r) throw new Error("탑승자가 아닙니다.");
        const t = now();
        const left = PROBLEM_COOLDOWN_MS - (t - (r.issueAt || 0));
        if (r.status === RIDER_STATUS.ISSUE && left > 0) {
          throw new Error("이미 문제 처리 중입니다. " + Math.ceil(left / 60000) + "분 뒤 다시 시도하세요.");
        }
        r.issueAt = t;
        r.status = RIDER_STATUS.ISSUE;
        r.issueReason = reason || "";
        return { userId: userId, status: r.status, cooldownEndsAt: t + PROBLEM_COOLDOWN_MS };
      },

      /* 노쇼 경고 — 10분 쿨다운 계산 */
      warnNoShow: function (userId) {
        const r = _rider(userId);
        if (!r) throw new Error("탑승자가 아닙니다.");
        const t = now();
        const left = NOSHOW_COOLDOWN_MS - (t - (r.noshowAt || 0));
        if (left > 0) {
          throw new Error("이미 경고를 보냈습니다. " + Math.ceil(left / 60000) + "분 뒤 다시 보낼 수 있습니다.");
        }
        r.noshowAt = t;
        r.status = RIDER_STATUS.NOSHOW;
        return { userId: userId, status: r.status, cooldownEndsAt: t + NOSHOW_COOLDOWN_MS };
      },

      /* 운송장 등록 — 숫자만 허용(공백/하이픈만 정리), 6자리 이상 */
      registerTracking: function (userId, trackingNum, courierName) {
        const r = _rider(userId);
        if (!r) throw new Error("탑승자가 아닙니다.");
        const digits = String(trackingNum == null ? "" : trackingNum).replace(/[\s-]/g, "");
        if (!/^\d+$/.test(digits)) throw new Error("운송장 번호는 숫자만 입력할 수 있습니다.");
        if (digits.length < 6) throw new Error("운송장 번호 형식이 올바르지 않습니다. (6자리 이상)");
        r.courierName = courierName || r.courierName || "택배";
        r.trackingNumber = digits;
        return { userId: userId, courierName: r.courierName, trackingNumber: digits };
      },

      /* ── 트랜잭션 락(블랙컨슈머 방어): 주문 시작 후 파티원 수정/취소 차단 ── */
      /* 파티원 정보 수정 */
      editRiderInfo: function (userId, patch) {
        const r = _rider(userId);
        if (!r) throw new Error("탑승자가 아닙니다.");
        if (coop.status === COOP_STATUS.CANCELLED) throw new Error("무산된 공구는 수정할 수 없습니다.");
        if (coop.isOrderStarted) throw new Error("주문이 시작되어 정보를 수정할 수 없습니다. (트랜잭션 잠금)");
        if (patch && typeof patch === "object") {
          ["courierName"].forEach(function (k) {
            if (Object.prototype.hasOwnProperty.call(patch, k)) r[k] = patch[k];
          });
        }
        return true;
      },

      /* 파티원 탑승 취소 → 보증금 환불 + 라이더 제거 */
      cancelRide: function (userId) {
        const r = _rider(userId);
        if (!r) throw new Error("탑승자가 아닙니다.");
        if (coop.status === COOP_STATUS.CANCELLED) throw new Error("무산된 공구입니다.");
        if (coop.isOrderStarted) throw new Error("주문이 시작되어 탑승을 취소할 수 없습니다. (트랜잭션 잠금)");
        const u = _users.get(userId);
        if (u && r.deposit > 0) u.points += r.deposit;   // 보증금 환불
        coop.riders.splice(coop.riders.indexOf(r), 1);
        return true;
      },

      /* ── 무산 & 환불 ── */
      /* 공구 무산: 상태 cancelled + 보증금(300P) 자동 환불 + 방장 페널티(귀책 시) */
      cancelCoop: function (adminId, reason, fault) {
        _requireHostOrAdmin(adminId);
        if (coop.status === COOP_STATUS.CANCELLED) throw new Error("이미 무산된 공구입니다.");
        if (coop.status === COOP_STATUS.DONE) throw new Error("완료된 공구는 무산할 수 없습니다.");
        if (!reason || !String(reason).trim()) throw new Error("무산 사유는 필수입니다.");
        const f = (fault === FAULT.FORCE_MAJEURE) ? FAULT.FORCE_MAJEURE : FAULT.HOST;

        coop.status = COOP_STATUS.CANCELLED;
        coop.cancelReason = String(reason).trim();
        coop.cancelFault = f;
        coop.cancelledAt = now();
        coop.refundRequestedAt = now();

        // 보증금(300P) 자동 환불 + 환불 대기 상태 전환
        let refunded = 0;
        coop.riders.forEach(function (r) {
          if (r.deposit > 0) {
            const u = _users.get(r.userId);
            if (u) { u.points += r.deposit; refunded += r.deposit; }
          }
          r.refundStatus = REFUND_STATUS.PENDING;
        });

        // 방장 귀책 페널티
        let suspended = false;
        if (f === FAULT.HOST) {
          const host = _users.get(coop.hostId);
          if (host) {
            host.cancelCount = (host.cancelCount || 0) + 1;
            host.trustScore = Math.max(0, (host.trustScore == null ? 100 : host.trustScore) - HOST_FAULT_PENALTY);
            if (host.cancelCount >= MAX_CANCELS) host.hostSuspended = true;
            suspended = host.hostSuspended;
          }
        }
        return {
          status: coop.status,
          fault: f,
          refundedDepositTotal: refunded,
          riderCount: coop.riders.length,
          hostSuspended: suspended,
        };
      },

      /* 방장: 현금 환불 증빙(이체확인증) 업로드 */
      uploadRefundProof: function (adminId, proofUrl) {
        _requireHostOrAdmin(adminId);
        if (coop.status !== COOP_STATUS.CANCELLED) throw new Error("무산된 공구에만 환불 증빙을 등록할 수 있습니다.");
        if (!proofUrl || !String(proofUrl).trim()) throw new Error("환불 증빙(이체확인증)이 필요합니다.");
        coop.refundProofUrl = String(proofUrl).trim();
        return true;
      },

      /* 파티원: 환불금 입금 확인 → 해당 내역 최종 종료(refund-completed) */
      confirmRefund: function (userId) {
        const r = _rider(userId);
        if (!r) throw new Error("탑승자가 아닙니다.");
        if (coop.status !== COOP_STATUS.CANCELLED) throw new Error("무산된 공구가 아닙니다.");
        if (!coop.refundProofUrl) throw new Error("방장의 환불 증빙이 아직 등록되지 않았습니다.");
        if (r.refundStatus === REFUND_STATUS.COMPLETED) throw new Error("이미 환불 완료가 확인된 내역입니다.");
        r.refundStatus = REFUND_STATUS.COMPLETED;
        return true;
      },

      /* 환불 마감(24h) 점검 → 독촉/분쟁 신호 반환 (실제 알림 발송은 호출측 책임) */
      checkRefundDeadline: function () {
        if (coop.status !== COOP_STATUS.CANCELLED) return { overdue: false };
        if (coop.refundProofUrl) return { overdue: false, done: true };
        const elapsed = now() - (coop.refundRequestedAt || now());
        if (elapsed < REFUND_DEADLINE_MS) {
          return { overdue: false, action: "urge_reminder", remainingMs: REFUND_DEADLINE_MS - elapsed, hostId: coop.hostId };
        }
        return { overdue: true, action: "dispute_report", hostId: coop.hostId, coopId: coop.id };
      },

      /* 모든 파티원 환불 완료 시 true (정산 종료 판단용) */
      isFullyRefunded: function () {
        if (coop.status !== COOP_STATUS.CANCELLED) return false;
        return coop.riders.length > 0 && coop.riders.every(function (r) {
          return r.refundStatus === REFUND_STATUS.COMPLETED;
        });
      },
    };

    return api;
  }

  /* ════════════════════════════════════════════════════════════════
     자동 테스트 — 브라우저 콘솔에서 runCoopAutoTest() 실행
     (mock 시계로 쿨다운까지 검증, [✅ 통과]/[❌ 실패] 출력)
     ════════════════════════════════════════════════════════════════ */
  function runCoopAutoTest() {
    const out = [];
    let clk = 1700000000000;                 // mock now (쿨다운 검증용)
    const now = function () { return clk; };
    function pass(m) { out.push("[✅ 통과] " + m); }
    function failed(m) { out.push("[❌ 실패] " + m); }
    function check(name, fn) {                // 정상 동작 기대 (true 반환)
      try { const r = fn(); if (r === false) failed(name + " — false 반환"); else pass(name); }
      catch (e) { failed(name + " — 예기치 못한 에러: " + e.message); }
    }
    function expectThrow(name, fn, frag) {    // 에러(방어) 기대
      try { fn(); failed(name + " — 에러가 발생하지 않음(방어 실패!)"); }
      catch (e) {
        if (!frag || e.message.indexOf(frag) !== -1) pass(name + " — 방어됨: " + e.message);
        else failed(name + " — 다른 에러: " + e.message);
      }
    }

    // ── 셋업 ──
    const host = createUserProfile("host", "contact@kaiwai.kr");
    const u1 = createUserProfile("u1", "party1@test.com"); u1.points = 500;
    const u2 = createUserProfile("u2", "party2@test.com"); u2.points = 100; // 포인트 부족 케이스
    const coop = createCoop({ id: "qa", hostId: "host", goalYen: 10000 });
    const sys = createCoopSystem(coop, [host, u1, u2], { now: now });

    // ── 1) 파티원 탑승 ──
    check("1) 파티원 탑승", function () { return sys.joinCoop("u1", 300) === true; });

    // ── 2) 방장의 주문 시작 (Lock) ──
    check("2) 방장 주문 시작 → Lock 작동", function () { return sys.startOrder("host") === true && coop.isOrderStarted === true; });

    // ── 3) Lock 이후 파티원 수정/취소 시도 (방어) ──
    expectThrow("3) Lock 후 정보 수정 차단", function () { sys.editRiderInfo("u1", { courierName: "CJ" }); }, "트랜잭션 잠금");
    expectThrow("3-2) Lock 후 탑승 취소 차단", function () { sys.cancelRide("u1"); }, "트랜잭션 잠금");

    // ── 4) 노쇼 경고 연속 2번 (쿨다운 방어) ──
    check("4) 노쇼 경고 1회 발송", function () { return !!sys.warnNoShow("u1"); });
    expectThrow("4-2) 노쇼 즉시 재발송 쿨다운 차단", function () { sys.warnNoShow("u1"); }, "다시 보낼");
    clk += 11 * 60 * 1000;                    // 11분 경과
    check("4-3) 10분 경과 후 재발송 가능", function () { return !!sys.warnNoShow("u1"); });

    // ── 보너스) 운송장 숫자 검증 ──
    expectThrow("5) 운송장 비숫자 차단", function () { sys.registerTracking("u1", "ABC123!!"); }, "숫자");
    check("5-2) 정상 운송장 등록", function () { return sys.registerTracking("u1", "1234-567-890").trackingNumber === "1234567890"; });

    // ── 출력 ──
    const fails = out.filter(function (s) { return s.indexOf("❌") !== -1; }).length;
    const passes = out.length - fails;
    const log = (typeof console !== "undefined") ? console : { log: function () {}, group: function () {}, groupEnd: function () {} };
    if (log.group) log.group("🧪 KAIWAI 공구 로직 자동 테스트");
    out.forEach(function (line) { log.log(line); });
    log.log("\n━━━━━━━━━━━━━━━━━━━━");
    log.log((fails === 0 ? "🎉 전체 통과" : "⚠️ 일부 실패") + " — 총 " + out.length + "건 / ✅ " + passes + " / ❌ " + fails);
    if (log.groupEnd) log.groupEnd();
    return { total: out.length, passed: passes, failed: fails, results: out };
  }

  /* ════════════════════════════════════════════════════════════════
     상품 스크래퍼 테스트 — 브라우저 콘솔에서 runScraperTest("URL") 실행
     실제 추출 결과(title/imageUrl/price)를 console.table 로 출력
     ════════════════════════════════════════════════════════════════ */
  async function runScraperTest(url) {
    const target = url || "https://example.com/products/sample-item";
    const log = (typeof console !== "undefined") ? console : { log: function () {}, table: function () {} };

    // 1) 잘못된 URL 사전 차단 검증
    log.log("🧪 스크래퍼 테스트 — 잘못된 입력 사전 차단 확인");
    try { await fetchProductDataFromUrl("그냥텍스트123"); log.log("[❌ 실패] 이상 입력이 차단되지 않음"); }
    catch (e) { log.log("[✅ 통과] 이상 입력 차단됨: " + e.message); }

    // 2) 실제 URL 스크래핑
    log.log("\n🔎 스크래핑 대상: " + target);
    let r;
    try { r = await fetchProductDataFromUrl(target); }
    catch (e) { log.log("[❌ 실패] URL 형식 오류: " + e.message); return null; }

    log.table([{
      "상품명(title)": r.title,
      "이미지(imageUrl)": r.imageUrl || "(없음)",
      "가격(price)": r.price,
      "성공(ok)": r.ok,
    }]);
    log.log(r.ok ? "✅ 추출 성공" : "⚠️ 차단/정보없음 → 안전 폴백(\"" + r.title + "\") 반환 [reason: " + (r.reason || "-") + "]");
    return r;
  }

  const CoopCore = {
    ADMIN_EMAILS: ADMIN_EMAILS,
    DEPOSIT: DEPOSIT,
    PROBLEM_COOLDOWN_MS: PROBLEM_COOLDOWN_MS,
    NOSHOW_COOLDOWN_MS: NOSHOW_COOLDOWN_MS,
    REFUND_DEADLINE_MS: REFUND_DEADLINE_MS,
    MAX_CANCELS: MAX_CANCELS,
    HOST_FAULT_PENALTY: HOST_FAULT_PENALTY,
    COOP_STATUS: COOP_STATUS,
    RIDER_STATUS: RIDER_STATUS,
    REFUND_STATUS: REFUND_STATUS,
    FAULT: FAULT,
    checkAdmin: checkAdmin,
    createUserProfile: createUserProfile,
    createCoop: createCoop,
    createCoopSystem: createCoopSystem,
    runCoopAutoTest: runCoopAutoTest,
    fetchProductDataFromUrl: fetchProductDataFromUrl,
    parseProductHtml: parseProductHtml,
    validateUrl: validateUrl,
    runScraperTest: runScraperTest,
  };

  if (typeof module !== "undefined" && module.exports) module.exports = CoopCore;
  else global.CoopCore = CoopCore;
  // 브라우저 콘솔에서 바로 호출 가능하도록 전역 노출
  if (typeof global !== "undefined") { global.runCoopAutoTest = runCoopAutoTest; global.runScraperTest = runScraperTest; }
})(typeof window !== "undefined" ? window : (typeof globalThis !== "undefined" ? globalThis : this));
