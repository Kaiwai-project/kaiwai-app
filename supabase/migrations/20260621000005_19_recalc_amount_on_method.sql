-- ============================================================
-- 19_recalc_amount_on_method.sql
--   method(수령방법) 변경 시 배송비 자동 재계산 트리거 보강
--   (Slice 3 후속: "method 를 바꾸면 amount 가 동결된다"는 분쟁 유발 버그 제거)
--
--   guard_bus_rider_update 재정의 — 비방장(파티원 본인)이 자기 행을 UPDATE 할 때:
--     · amount 를 OLD 로 동결하던 로직을 제거하고, 서버가 직접 재계산한다.
--         goods   = OLD.yen * OLD.qty * 9   (yen/qty 는 여전히 동결값 → Zero-Yen 방어)
--         배송비   = conv→1800, home→3500,
--                   etc→기존 배송비 차액(OLD.amount - goods) 보존(직접입력값이라 역산 불가)
--         amount  = goods + 배송비
--     · 클라이언트가 보낸 amount 는 무시(동결)하므로 위변조 불가.
--     · product_name/qty/yen(상품)·paid/issue/issue_text(방장)·tracking/courier(방장) 동결,
--       power(도수)·method(수령방법) 본인 허용 정책은 18 과 동일하게 유지.
--   (RLS 정책은 18 그대로 — 이 마이그레이션은 트리거 함수만 보강한다.)
-- ============================================================
create or replace function public.guard_bus_rider_update()
returns trigger
language plpgsql
as $$
declare
  is_owner boolean;
  v_goods  integer;
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
    -- 상품 데이터: 동결 (무결성 / Zero-Yen 방어)
    new.product_name    := old.product_name;
    new.qty             := old.qty;
    new.yen             := old.yen;
    -- 운송장: 방장 전용
    new.tracking_number := old.tracking_number;
    new.courier_name    := old.courier_name;
    -- power(도수)·method(수령방법): 본인 수정 허용 → 동결 안 함

    -- amount: 클라가 보낸 값 무시 → 동결된 yen/qty + (변경 가능한) method 로 서버 재계산.
    --   배송비: conv 1800 / home 3500 / etc 는 기존 배송비 차액 보존.
    v_goods := old.yen * old.qty * 9;
    new.amount := v_goods + (case new.method
                               when 'conv' then 1800
                               when 'home' then 3500
                               else greatest(old.amount - v_goods, 0)
                             end);
  end if;
  return new;
end;
$$;
