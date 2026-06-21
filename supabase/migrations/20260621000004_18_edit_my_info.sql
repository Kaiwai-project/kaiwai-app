-- ============================================================
-- 18_edit_my_info.sql  —  파티원 본인 정보 수정(editMyInfo) 지원
--   guard_bus_rider_update 트리거 재정의:
--   비방장(본인)이 자기 행을 UPDATE 할 때
--     · 동결 유지: product_name, qty, yen, amount (금융/금액 = Zero-Yen 방어)
--                  paid, issue, issue_text, tracking_number, courier_name (방장 전용)
--     · 잠금 해제: power(도수), method(수령방법)  ← Slice 3 신규 허용
--   (PII 수정은 bus_rider_private 의 "개인정보 수정 잠금" RLS 가
--    ordered=false AND 본인 paid=false 일 때만 별도 허용)
-- ============================================================
create or replace function public.guard_bus_rider_update()
returns trigger
language plpgsql
as $$
declare
  is_owner boolean;
begin
  select (b.owner_id = auth.uid())
    into is_owner
    from public.buses b
   where b.id = new.bus_id;

  if not coalesce(is_owner, false) then
    -- 결제/이슈 상태: 방장 전용
    new.paid            := old.paid;
    new.issue           := old.issue;
    new.issue_text      := old.issue_text;
    -- 금융·상품 데이터: 동결 (무결성)
    new.product_name    := old.product_name;
    new.qty             := old.qty;
    new.yen             := old.yen;
    new.amount          := old.amount;
    -- 운송장: 방장 전용
    new.tracking_number := old.tracking_number;
    new.courier_name    := old.courier_name;
    -- power(도수)·method(수령방법): 본인 수정 허용 → 동결 안 함
  end if;
  return new;
end;
$$;

-- bus_riders UPDATE 정책 보강: 방장은 항상, 본인은 '미주문'일 때만 수정 가능.
--   (기존 정책은 ordered 무관하게 본인 수정 허용 → 주문완료 후에도 파티원이
--    직접 API 로 power/method 를 바꿀 수 있던 갭. 방장은 주문 후 운송장 등록이
--    필요하므로 ordered 무관 유지.)
drop policy if exists "장부 수정: 본인 또는 방장" on public.bus_riders;
create policy "장부 수정: 방장 또는 본인(미주문)" on public.bus_riders
  for update to authenticated
  using (
    exists (select 1 from public.buses b where b.id = bus_id and b.owner_id = auth.uid())
    or (user_id = auth.uid()
        and exists (select 1 from public.buses b where b.id = bus_id and b.ordered = false))
  )
  with check (
    exists (select 1 from public.buses b where b.id = bus_id and b.owner_id = auth.uid())
    or (user_id = auth.uid()
        and exists (select 1 from public.buses b where b.id = bus_id and b.ordered = false))
  );
