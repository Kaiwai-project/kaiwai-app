-- ============================================================
-- 32_bus_platform_power.sql  —  개설 폼: 플랫폼/총대 좌우 도수 저장
--   · platform     : 공구 플랫폼(렌즈라라/기타) — 주문 모달·링크에서 사용(기존엔 미저장)
--   · host_power_l : 총대 본인 렌즈 도수(좌)
--   · host_power_r : 총대 본인 렌즈 도수(우)
--   모두 비민감 메타데이터. buses 는 공개 SELECT 정책이라 별도 RLS 불필요.
-- ============================================================
alter table public.buses
  add column if not exists platform     text not null default '렌즈라라',
  add column if not exists host_power_l text,
  add column if not exists host_power_r text;
