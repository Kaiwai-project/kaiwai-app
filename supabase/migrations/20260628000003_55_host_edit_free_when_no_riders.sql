-- ============================================================
-- 55_host_edit_free_when_no_riders.sql
--   총대 공구 옵션 수정 1회 제한을 '탑승자가 있을 때만' 적용.
--   탑승자 0명이면 보호 대상이 없으므로 자유 수정(host_edited 소진 안 함).
--   → mig54 의 guard_bus_host_options 를 그 조건만 추가해 재정의.
-- ============================================================
create or replace function public.guard_bus_host_options()
returns trigger
language plpgsql
as $$
begin
  -- 상품/가격/수량/도수 옵션 필드가 실제로 바뀐 경우에만 게이트 적용
  if (new.product_name  is distinct from old.product_name
   or new.product_price is distinct from old.product_price
   or new.host_qty      is distinct from old.host_qty
   or new.host_power_l  is distinct from old.host_power_l
   or new.host_power_r  is distinct from old.host_power_r) then
    if auth.uid() = old.owner_id then
      -- 탑승자가 1명이라도 있을 때만 1회 제한 적용. 없으면 자유 수정(소진 안 함).
      if exists (select 1 from public.bus_riders where bus_id = old.id) then
        if old.host_edited then
          raise exception '공구 옵션 수정은 1회만 가능합니다' using errcode = 'P0001';
        end if;
        new.host_edited := true;
      end if;
    elsif not public.is_app_admin(auth.uid()) then
      raise exception '방장만 공구 옵션을 수정할 수 있습니다' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
