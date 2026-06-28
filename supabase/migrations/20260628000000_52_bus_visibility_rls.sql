-- ============================================================
-- 52_bus_visibility_rls.sql  —  공구 버스 가시성 차단 정책 (DB 레벨 원천 차단)
--
--   출발(ordered=true)한 버스는 아래 중 하나라도 만족할 때만 조회 가능:
--     1. not ordered          → 출발 전 버스는 모두에게 공개(브라우징)
--     2. auth.uid() = owner_id → 해당 방의 총대(방장)
--     3. bus_riders 에 본인 user_id 가 기록됨 → 탑승자
--     4. public.is_app_admin   → 앱 최고 관리자
--   그 외 유저에게는 buses 행 자체가 SELECT 되지 않음(프론트 필터가 아닌 RLS 원천 차단).
--
--   ⚠️ 컬럼충돌 주의: EXISTS 서브쿼리의 대상 테이블 bus_riders 에도 `id`(PK) 컬럼이 있어,
--      unqualified `id` 는 buses.id 가 아니라 bus_riders.id 로 바인딩된다(마이그17이 겪은 버그).
--      → 반드시 `buses.id` 로 한정해야 상관 서브쿼리가 올바르게 동작한다.
--   ※ bus_riders 의 "장부 공개 조회"(using true) 정책은 buses 를 참조하지 않으므로 재귀 RLS 없음.
-- ============================================================

-- 1) 기존 무조건 공개(using true) 정책 제거 (마이그14에서 생성)
drop policy if exists "공구방 공개 조회" on public.buses;

-- 2) 가시성 제한 SELECT 정책 (재적용 안전을 위해 동일 이름 선삭제)
drop policy if exists "출발 전 공개, 출발 후 참가자+관리자 전용" on public.buses;
create policy "출발 전 공개, 출발 후 참가자+관리자 전용" on public.buses
  for select using (
    not ordered
    or auth.uid() = owner_id
    or exists (
      select 1 from public.bus_riders r
      where r.bus_id = buses.id          -- buses.id 로 한정 (bus_riders.id 와의 충돌 방지)
        and r.user_id = auth.uid()
    )
    or public.is_app_admin(auth.uid())
  );
