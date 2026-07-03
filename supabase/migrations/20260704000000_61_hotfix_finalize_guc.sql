-- ============================================================
-- 61_hotfix_finalize_guc.sql  —  [HOTFIX · Blocker] 배송완료(finalize) 차단 복구
--
--   [증상] 비관리자 총대의 finalize_coop(배송 완료 처리)가
--          "마감된 공구는 수정할 수 없습니다" 로 차단 → 상호평가·총대 수고비 적립 불가.
--
--   [근본 원인] 가드 우회 GUC 이름 불일치 (렌즈 제거와 무관, mig56 부터 존재)
--     · finalize_coop (mig45): set_config('app.allow_finalize','1') 로 우회 시도.
--     · guard_bus_update_after_ordered (mig45): app.allow_finalize 를 체크 → 정상 우회.
--     · 그런데 mig56 이 가드를 재정의하며 우회 GUC 를 app.allow_coop_transition 으로 바꾸고
--       app.allow_finalize 체크를 통째로 제거 → finalize 의 GUC 를 새 가드가 무시 → 차단.
--
--   [수정] 가드가 두 GUC 를 모두 우회 허용하도록 재정의.
--     · app.allow_coop_transition = 라이프사이클 전이 RPC(mig56/57) 용 — 보존
--     · app.allow_finalize        = finalize_coop(mig45) 용 — 복구
--     finalize_coop / 전이 RPC 본문은 일절 수정하지 않는다(무수정 = 최소 위험).
--     mig56 본문 + search_path 명시(mig45 와 동일) + allow_finalize 우회만 추가.
-- ============================================================
create or replace function public.guard_bus_update_after_ordered()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  -- 라이프사이클 전이(mig56) 또는 배송완료(mig45) RPC 의 트랜잭션-로컬 GUC 면 우회
  v_flag boolean := coalesce(current_setting('app.allow_coop_transition', true), '') = '1'
                 or coalesce(current_setting('app.allow_finalize',        true), '') = '1';
begin
  -- 마감된 공구 수정 제한 (어드민·전이RPC·finalize 제외)
  if old.ordered = true then
    if not v_flag and not public.is_app_admin(auth.uid()) then
      raise exception '마감된 공구는 수정할 수 없습니다' using errcode = 'P0001';
    end if;
  end if;

  -- 마감(ordered=true)으로 전환할 때 핵심 상품 정보 동시 조작 방어
  if old.ordered = false and new.ordered = true then
    if new.product_name is distinct from old.product_name or
       new.product_price is distinct from old.product_price or
       new.host_qty is distinct from old.host_qty or
       new.goal is distinct from old.goal or
       new.minimum_goal is distinct from old.minimum_goal then
      raise exception '마감 처리 중에는 상품 정보를 변경할 수 없습니다' using errcode = 'P0001';
    end if;
  end if;

  return new;
end;
$$;
-- (트리거 trg_guard_bus_update_after_ordered 는 mig43 에서 이미 생성됨 — 재생성 불필요)
