# God Mode 운영도구 구현 계획 (피드/공구 강제삭제 · 유저 포인트 ±지급)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 관리자(God Mode)가 부적절한 피드 게시물·공구방을 강제삭제하고 특정 유저에게 포인트를 ±지급할 수 있게 한다.

**Architecture:** Supabase `SECURITY DEFINER` RPC 3종(+enum 1값)을 추가하고, 기존 `is_app_admin(uuid)` 화이트리스트로 게이트. 클라(index.html)는 기존 God Override 토글·god 패널 패턴을 그대로 확장한다.

**Tech Stack:** Supabase(PostgreSQL 15, RLS), 정적 HTML/Vanilla JS(index.html), supabase-js v2.

**검증 방식:** 이 레포는 pytest형 단위테스트가 없다. SQL은 **Supabase SQL Editor / psql 로 RPC 직접호출**하여 검증하고, 클라는 **브라우저에서 God Mode 동작 확인**한다. 마이그레이션 적용은 `supabase db push`.

**스펙:** `docs/superpowers/specs/2026-06-26-admin-god-mode-moderation-design.md`

---

## File Structure

- Create: `supabase/migrations/20260626000000_49_point_reason_admin_revoke.sql` — point_reason enum 에 `admin_revoke` 추가 (단독 — `alter type add value` 트랜잭션 제약 회피)
- Create: `supabase/migrations/20260626000001_50_god_mode_admin_tools.sql` — `god_force_delete_post`, `admin_grant_points_to`, `admin_search_users` 3개 RPC
- Modify: `index.html` — 피드 강제삭제 버튼(`drawFeed`/`renderPostDetail`), god 패널 "유저 포인트 관리" 섹션, 카드 작성자 프리필 진입점

---

## Task 1: enum `admin_revoke` 추가 마이그레이션

**Files:**
- Create: `supabase/migrations/20260626000000_49_point_reason_admin_revoke.sql`

- [ ] **Step 1: 마이그레이션 파일 작성**

```sql
-- ============================================================
-- 49_point_reason_admin_revoke.sql
--   관리자 음수 차감(admin_grant_points_to 의 -amount) 감사용 사유값 추가.
--   ※ alter type ... add value 는 같은 트랜잭션에서 그 값을 literal 로 즉시
--     사용할 수 없으므로, 함수(마이그50)와 분리된 단독 마이그레이션으로 둔다.
-- ============================================================
alter type public.point_reason add value if not exists 'admin_revoke';
```

- [ ] **Step 2: 적용 & 검증**

Run: `supabase db push`
그 다음 SQL Editor 에서:
```sql
select unnest(enum_range(null::public.point_reason));
```
Expected: 결과에 `admin_grant` 와 새 `admin_revoke` 가 모두 보임.

- [ ] **Step 3: 커밋**

```bash
git add supabase/migrations/20260626000000_49_point_reason_admin_revoke.sql
git commit -m "feat(db): point_reason 에 admin_revoke 사유 추가"
```

---

## Task 2: God Mode RPC 3종 마이그레이션

**Files:**
- Create: `supabase/migrations/20260626000001_50_god_mode_admin_tools.sql`

- [ ] **Step 1: 마이그레이션 파일 작성**

```sql
-- ============================================================
-- 50_god_mode_admin_tools.sql  —  God Mode 운영도구
--   1) god_force_delete_post : 부적절 피드 게시물 강제삭제 (post_likes cascade)
--   2) admin_grant_points_to : 특정 유저에게 포인트 ±지급 (잔액 0 미만 불가)
--   3) admin_search_users    : 닉네임/아이디로 유저 검색 (지급 대상 선택용)
--   게이트: 전부 is_app_admin(auth.uid()) (마이그33 화이트리스트) 재사용.
-- ============================================================

-- 1) 피드 게시물 강제삭제 -----------------------------------------------------
create or replace function public.god_force_delete_post(p_post_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;
  if not public.is_app_admin(v_uid) then
    raise exception '관리자 전용 기능입니다' using errcode = '42501';
  end if;

  perform 1 from public.posts where id = p_post_id for update;
  if not found then
    raise exception '존재하지 않거나 이미 삭제된 게시물입니다' using errcode = 'P0001';
  end if;

  delete from public.posts where id = p_post_id;  -- post_likes 는 ON DELETE CASCADE

  return jsonb_build_object('deleted', true, 'post_id', p_post_id);
end;
$$;
revoke all on function public.god_force_delete_post(uuid) from public, anon;
grant execute on function public.god_force_delete_post(uuid) to authenticated;

-- 2) 특정 유저 포인트 ±지급 ---------------------------------------------------
create or replace function public.admin_grant_points_to(p_target uuid, p_amount integer)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_reason public.point_reason;
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;
  if not public.is_app_admin(v_uid) then
    raise exception '관리자 전용 기능입니다' using errcode = '42501';
  end if;
  if p_target is null then raise exception '대상 유저가 없습니다' using errcode = 'P0001'; end if;
  if p_amount is null or p_amount = 0 or abs(p_amount) > 100000 then
    raise exception '지급/차감액이 올바르지 않습니다 (±1~100000)' using errcode = 'P0001';
  end if;

  v_reason := case when p_amount > 0 then 'admin_grant' else 'admin_revoke' end;
  -- 차감으로 잔액 < 0 이면 _wallet_apply 가 '포인트가 부족합니다'(P0001) raise → 롤백
  return public._wallet_apply(p_target, p_amount, v_reason,
                              null, 'god grant by ' || v_uid::text);
end;
$$;
revoke all on function public.admin_grant_points_to(uuid, integer) from public, anon;
grant execute on function public.admin_grant_points_to(uuid, integer) to authenticated;

-- 3) 유저 검색 (지급 대상 선택용) ---------------------------------------------
create or replace function public.admin_search_users(p_query text)
returns table (id uuid, display_name text, username text, balance integer)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_app_admin(auth.uid()) then
    raise exception '관리자 전용 기능입니다' using errcode = '42501';
  end if;
  if coalesce(length(trim(p_query)), 0) < 1 then return; end if;

  return query
    select p.id, p.display_name, p.username, coalesce(w.balance, 0)
      from public.profiles p
      left join public.user_wallets w on w.user_id = p.id
     where p.display_name ilike '%' || p_query || '%'
        or p.username     ilike '%' || p_query || '%'
     order by p.display_name
     limit 20;
end;
$$;
revoke all on function public.admin_search_users(text) from public, anon;
grant execute on function public.admin_search_users(text) to authenticated;
```

- [ ] **Step 2: 적용**

Run: `supabase db push`
Expected: 3개 함수 생성 성공, 에러 없음.

- [ ] **Step 3: 관리자 계정으로 RPC 동작 검증 (SQL Editor, 관리자 세션)**

```sql
-- (a) 유저 검색
select * from public.admin_search_users('a');           -- 후보 + 잔액 반환
-- (b) 포인트 지급/차감 (실제 유저 uuid 로 교체)
select public.admin_grant_points_to('<TARGET_UUID>', 500);   -- 새 잔액 +500
select public.admin_grant_points_to('<TARGET_UUID>', -300);  -- 새 잔액 -300
-- (c) 원장 기록 확인
select delta, reason, memo from public.point_transactions
  where user_id = '<TARGET_UUID>' order by created_at desc limit 2;
-- Expected: (500, admin_grant, 'god grant by ...'), (-300, admin_revoke, 'god grant by ...')
```

- [ ] **Step 4: 거부/경계 케이스 검증**

```sql
-- 한도 초과 → P0001
select public.admin_grant_points_to('<TARGET_UUID>', 200000);
-- 잔액보다 큰 차감 → '포인트가 부족합니다' P0001 (롤백, 잔액 0 미만 금지 확인)
select public.admin_grant_points_to('<TARGET_UUID>', -99999999);
-- 비관리자 세션에서 호출 → '관리자 전용 기능입니다' 42501
```
Expected: 위 모두 해당 에러로 거부, 잔액은 음수로 내려가지 않음.

- [ ] **Step 5: 커밋**

```bash
git add supabase/migrations/20260626000001_50_god_mode_admin_tools.sql
git commit -m "feat(db): God Mode RPC(피드 강제삭제·유저 포인트 ±지급·유저 검색) 추가"
```

---

## Task 3: 피드 게시물 강제삭제 UI (index.html)

**Files:**
- Modify: `index.html` (`drawFeed` 약 5151행, `renderPostDetail` 약 5295행, 피드 RPC 헬퍼)

- [ ] **Step 1: 강제삭제 헬퍼 함수 추가**

`drawFeed` 정의 근처(피드 관련 함수 영역)에 추가. `_godOverride`/`isAdminUser`/`showToast`/`FEED`/`loadFeed`/`drawFeed` 는 기존 전역.

```js
// God Override(관리자 + 토글 ON): 부적절 피드 게시물 강제 삭제
async function godForceDeletePost(postId){
  if(!(_godOverride && isAdminUser())) return;
  if(!confirm("[God Override] 이 게시물을 강제 삭제할까요?\n되돌릴 수 없습니다.")) return;
  try{
    const { error } = await window.sb.rpc("god_force_delete_post", { p_post_id: postId });
    if(error) throw error;
    if(typeof FEED !== "undefined" && Array.isArray(FEED)){
      const i = FEED.findIndex(x => x.id === postId);
      if(i >= 0) FEED.splice(i, 1);
    }
    showToast("게시물을 삭제했습니다 🗑️");
    if(typeof drawFeed === "function") drawFeed();
    go("feed");   // 상세 화면이었다면 피드 탭으로 복귀
  }catch(e){
    showToast("삭제 실패: " + (e.message || e));
  }
}
```

- [ ] **Step 2: `drawFeed` 카드에 🗑️ 버튼 삽입**

`drawFeed()` 내부에서 각 게시물 카드 HTML 을 만드는 부분에, 카드 마크업 안에 아래를 추가(관리자 + 토글 ON 일 때만 렌더). `p.id` 는 해당 카드의 게시물 id.

```js
// 카드 HTML 문자열 조립부에서 — 관리자 강제삭제 오버레이 버튼
const godDelBtn = (_godOverride && isAdminUser())
  ? `<button onclick="event.stopPropagation();godForceDeletePost('${p.id}')"
       style="position:absolute;top:6px;right:6px;z-index:5;width:30px;height:30px;border-radius:50%;
              border:1.5px solid #E5484D;background:rgba(58,26,34,.92);color:#fff;cursor:pointer;
              font-size:13px;box-shadow:0 2px 8px rgba(0,0,0,.4)" title="강제 삭제">🗑️</button>`
  : "";
```
조립한 `godDelBtn` 을 카드 컨테이너(`position:relative` 인 래퍼) 안에 포함시킨다. 카드 래퍼에 `position:relative` 가 없으면 추가.

- [ ] **Step 3: `renderPostDetail` 상세 화면에도 버튼 추가**

`renderPostDetail()` 의 상세 헤더/액션 영역에 동일 게이트로 버튼 삽입. 상세에서 보고 있는 게시물 id 변수(예: 현재 `p.id` 또는 상세용 변수)를 사용.

```js
// 상세 액션 바에 삽입할 문자열
const godDelDetail = (_godOverride && isAdminUser())
  ? `<button onclick="godForceDeletePost('${p.id}')"
       style="border:1.5px solid #E5484D;background:#3A1A22;color:#fff;border-radius:10px;
              padding:8px 12px;font-size:12px;font-weight:800;cursor:pointer">🗑️ 강제삭제</button>`
  : "";
```

- [ ] **Step 4: 브라우저 검증**

1. 관리자 계정 로그인 → 🐞 godFab → 패널에서 "모든 제약 우회" ON.
2. 피드 탭: 각 카드 우상단에 🗑️ 노출 확인. 비관리자/토글 OFF 시 미노출 확인.
3. 🗑️ → confirm → 삭제 → 카드 사라지고 토스트. 새로고침 후에도 삭제 유지(DB 반영).

- [ ] **Step 5: 커밋**

```bash
git add index.html
git commit -m "feat(feed): God Override 시 피드 게시물 강제삭제 버튼"
```

---

## Task 4: god 패널 "유저 포인트 관리" 섹션 (index.html)

**Files:**
- Modify: `index.html` (godOverlay 마크업 ~410-424행, god 함수 영역 ~2320-2399행)

- [ ] **Step 1: god 패널에 UI 섹션 추가**

`godOverlay` 내부, 기존 버튼 그리드와 `godOverrideBtn` 사이(또는 아래)에 삽입:

```html
<!-- 🎁 유저 포인트 관리 (관리자 전용) -->
<div style="margin-top:12px;border-top:1px solid #241C38;padding-top:12px">
  <div style="font-size:12px;font-weight:800;color:#FFD166;margin-bottom:8px;font-family:'Jua','Gowun Dodum',sans-serif">🎁 유저 포인트 관리</div>
  <div style="display:flex;gap:6px;margin-bottom:8px">
    <input id="godUserQuery" placeholder="닉네임/아이디 검색" oninput="godSearchUsers(this.value)"
      style="flex:1;background:#0C0916;border:1px solid #241C38;border-radius:10px;padding:9px;color:#E8DFF5;font-size:12px">
  </div>
  <div id="godUserResults" style="max-height:130px;overflow:auto;margin-bottom:8px"></div>
  <div id="godGrantBox" style="display:none">
    <div id="godGrantTarget" style="font-size:11px;color:#B6E6CA;margin-bottom:6px"></div>
    <div style="display:flex;gap:6px">
      <input id="godGrantAmount" type="number" placeholder="±포인트 (예: 500 / -300)"
        style="flex:1;background:#0C0916;border:1px solid #241C38;border-radius:10px;padding:9px;color:#E8DFF5;font-size:12px">
      <button onclick="godGrantToSelected()"
        style="border:none;cursor:pointer;border-radius:10px;padding:9px 14px;font-size:12px;font-weight:800;color:#1B1430;background:#FFD166;font-family:'Jua','Gowun Dodum',sans-serif">지급</button>
    </div>
  </div>
</div>
```

- [ ] **Step 2: 검색/선택/지급 함수 추가**

god 함수 영역(예: `godAddPoints` 근처)에 추가. `escapeHtml` 등 기존 유틸이 있으면 사용, 없으면 아래처럼 텍스트만 안전 삽입.

```js
let _godGrantTargetId = null;
let _godSearchTimer = null;

function godSearchUsers(q){
  clearTimeout(_godSearchTimer);
  _godSearchTimer = setTimeout(async () => {
    const box = document.getElementById("godUserResults");
    if(!q || !q.trim()){ box.innerHTML = ""; return; }
    try{
      const { data, error } = await window.sb.rpc("admin_search_users", { p_query: q.trim() });
      if(error) throw error;
      if(!data || !data.length){ box.innerHTML = '<div style="font-size:11px;color:#6B6486;padding:6px">결과 없음</div>'; return; }
      box.innerHTML = data.map(u => {
        const name = (u.display_name || u.username || "(이름없음)");
        const safe = name.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;");
        return `<button onclick="godPickUser('${u.id}','${safe.replace(/'/g,"\\'")}', ${u.balance})"
          style="display:flex;justify-content:space-between;width:100%;gap:8px;text-align:left;cursor:pointer;
                 background:#0C0916;border:1px solid #241C38;border-radius:8px;padding:8px;margin-bottom:5px;color:#E8DFF5;font-size:12px">
          <span>${safe}</span><span style="color:#FFD166">${u.balance}P</span></button>`;
      }).join("");
    }catch(e){
      box.innerHTML = '<div style="font-size:11px;color:#FF8A8A;padding:6px">검색 실패: '+(e.message||e)+'</div>';
    }
  }, 250);
}

function godPickUser(id, name, balance){
  _godGrantTargetId = id;
  document.getElementById("godGrantBox").style.display = "block";
  document.getElementById("godGrantTarget").textContent = "대상: " + name + " (현재 " + balance + "P)";
  document.getElementById("godGrantAmount").value = "";
  document.getElementById("godGrantAmount").focus();
}

async function godGrantToSelected(){
  if(!_godGrantTargetId){ showToast("대상 유저를 먼저 선택하세요"); return; }
  const amt = parseInt(document.getElementById("godGrantAmount").value, 10);
  if(!Number.isInteger(amt) || amt === 0){ showToast("±포인트를 올바르게 입력하세요"); return; }
  try{
    const { data, error } = await window.sb.rpc("admin_grant_points_to", { p_target: _godGrantTargetId, p_amount: amt });
    if(error) throw error;
    showToast((amt > 0 ? "지급" : "차감") + " 완료 — 새 잔액 " + data + "P 🪙");
    // 검색 결과 잔액 갱신
    const q = document.getElementById("godUserQuery").value;
    if(q) godSearchUsers(q);
  }catch(e){
    showToast("실패: " + (e.message || e));
  }
}
```

- [ ] **Step 3: 브라우저 검증**

1. 관리자 → godFab → 패널 "유저 포인트 관리" 노출.
2. 검색어 입력 → 후보 + 잔액 표시. 항목 선택 → 대상/현잔액 표시.
3. `500` 지급 → 토스트 새 잔액. `-300` 차감 → 토스트 새 잔액. 잔액 초과 차감 → "포인트가 부족합니다" 토스트(잔액 음수 안 됨).

- [ ] **Step 4: 커밋**

```bash
git add index.html
git commit -m "feat(god): god 패널에 특정 유저 포인트 ±지급/검색 UI"
```

---

## Task 5: 카드 작성자 프리필 진입점 (index.html)

**Files:**
- Modify: `index.html` (`drawFeed`/`renderPostDetail` 작성자 표시부, 공구 카드 작성자 표시부)

- [ ] **Step 1: 프리필 헬퍼 추가**

god 함수 영역에 추가. god 패널을 열고 특정 유저를 바로 선택 상태로 만든다.

```js
// 카드 작성자 → god 패널 "유저 포인트 관리" 에 바로 프리필
function godGrantToUser(userId, displayName){
  if(!(_godOverride && isAdminUser())) return;
  openGodPanel();
  godPickUser(userId, displayName || "(선택한 유저)", 0);  // 잔액은 지급 후 갱신됨
  document.getElementById("godGrantBox").scrollIntoView({ behavior:"smooth", block:"nearest" });
}
```

- [ ] **Step 2: 피드/공구 카드 작성자에 진입점 연결**

`drawFeed`/`renderPostDetail` 의 작성자(👤 닉네임) 요소와, 공구 카드(`coop-core.js` 또는 index.html 의 공구 렌더부)의 방장 표시 요소에, 관리자+토글 ON 일 때만 클릭 핸들러를 단다. 작성자 id 가 카드 데이터에 있어야 한다(`p.author_id`, 공구는 `b.owner_id`).

```js
// 예: 작성자 닉네임 span 옆 — 게이트 ON 일 때만
const godPointBtn = (_godOverride && isAdminUser())
  ? `<button onclick="event.stopPropagation();godGrantToUser('${p.author_id}','${(p.author_name||'').replace(/'/g,"\\'")}')"
       style="margin-left:6px;border:none;background:none;cursor:pointer;font-size:12px" title="이 유저에게 포인트">🎁</button>`
  : "";
```
> 공구 카드도 동일 패턴(`b.owner_id`, 방장 닉네임)으로 🎁 버튼 추가. 작성자/방장 id·닉네임 필드명이 다르면 해당 렌더 데이터에 맞춰 치환.

- [ ] **Step 3: 브라우저 검증**

1. 관리자 + 토글 ON → 피드/공구 카드 작성자 옆 🎁 노출.
2. 🎁 클릭 → god 패널 열리고 해당 유저가 선택된 상태 → 금액 입력 → 지급 → 토스트 새 잔액.

- [ ] **Step 4: 커밋**

```bash
git add index.html
git commit -m "feat(god): 피드/공구 카드 작성자에서 바로 포인트 지급 진입점"
```

---

## 완료 기준

- 관리자가 God Override ON 상태에서 피드 게시물·공구방을 강제삭제할 수 있다(공구방은 기존 기능 유지).
- 관리자가 닉네임 검색 또는 카드 작성자 클릭으로 특정 유저에게 포인트를 ±지급할 수 있다.
- 비관리자·토글 OFF 에서는 어떤 진입점도 노출되지 않고, 서버 RPC 도 42501 로 거부한다.
- 모든 포인트 변동이 `point_transactions` 원장에 사유·memo 와 함께 기록되고, 잔액은 음수가 되지 않는다.

## 주의사항

- 서버 `is_app_admin` ↔ 클라 `ADMIN_IDS`(index.html `5777행`, profile.js) 목록은 항상 일치 유지(마이그33 규칙).
- `drawFeed`/`renderPostDetail`/공구 렌더의 실제 변수명(`p.id`, `p.author_id`, `b.owner_id`, 닉네임 필드)은 구현 시 해당 함수의 실제 데이터 구조로 확인 후 치환할 것 — 본 계획의 변수명은 02_posts/14_lens_bus 스키마 기준 추정.
