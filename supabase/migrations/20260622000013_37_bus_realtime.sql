-- ============================================================
-- 37_bus_realtime.sql  —  공구방 투명 장부 실시간화
--
--   문제: 공구방 장부는 '실시간 투명 장부'라 표기되지만 실제 realtime 구독이 없어,
--         다른 탑승자가 새로 타거나 수량/수정/입금승인이 일어나도 방을 다시 열기 전엔
--         화면에 안 보였음("참여자 주문내역이 빠져 보임").
--   해결: bus_riders / buses 를 supabase_realtime publication 에 추가하고
--         REPLICA IDENTITY FULL 로 두어(DELETE old 에 bus_id 포함 → bus_id 필터 매칭),
--         클라가 열린 방의 변경을 구독해 즉시 전원 재렌더하도록 한다.
--   SELECT RLS 가 공개(using true)라 구독자는 그 방의 모든 장부 행 변경을 수신한다.
-- ============================================================

do $$
begin
  begin
    alter publication supabase_realtime add table public.bus_riders;
  exception when duplicate_object then null; end;
  begin
    alter publication supabase_realtime add table public.buses;
  exception when duplicate_object then null; end;
end $$;

alter table public.bus_riders replica identity full;
alter table public.buses      replica identity full;
