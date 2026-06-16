# -*- coding: utf-8 -*-
# 브랜드 로고(파비콘) 다운로드 — Clearbit 종료 대응판
#   · 데이터 출처: index.html 의 B 배열 (id, n, japanUrl)
#   · 로고 소스: icon.horse → Google → DuckDuckGo 순으로 폴백
#   · 콘솔 인코딩(cp949) 깨짐/크래시 방지

import re
import sys
import urllib.parse
import urllib.request
import urllib.error
import os
import time

# 콘솔이 cp949 라도 한글/일본어 출력에서 죽지 않도록 UTF-8 로 강제
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

def log(msg):
    # 만약을 위한 2차 안전장치
    try:
        print(msg)
    except Exception:
        print(msg.encode("ascii", "replace").decode("ascii"))

# 1. 데이터 읽기
file_path = "index.html"
with open(file_path, "r", encoding="utf-8") as f:
    content = f.read()

# 2. 저장 폴더
os.makedirs("logos", exist_ok=True)

# 3. id, 브랜드명(n), japanUrl 추출
blocks = re.findall(r'\{id:\s*(\d+).*?n:\s*"([^"]+)".*?japanUrl:\s*"([^"]+)"', content, re.DOTALL)
log(f"총 {len(blocks)}개 브랜드 도메인 발견. 로고 다운로드를 시작합니다...\n")

# 입점몰/마켓플레이스 — 받아져도 브랜드가 아닌 쇼핑몰 로고이니 표시만
MARKET = ("rakuten", "ailand-store", "zozo", "thebase", "stripe-club", "base.shop", "stores.jp")

# 로고 소스들 (순서대로 시도, 먼저 성공하는 것 채택)
def sources(domain):
    return [
        ("icon.horse", f"https://icon.horse/icon/{domain}"),
        ("google",     f"https://www.google.com/s2/favicons?domain={domain}&sz=128"),
        ("duckduckgo", f"https://icons.duckduckgo.com/ip3/{domain}.ico"),
    ]

def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=15) as r:
        data = r.read()
        ctype = r.headers.get("Content-Type", "")
    # 너무 작은 응답(빈 1px/에러 페이지)은 실패 취급
    if not data or len(data) < 100:
        raise ValueError(f"too small ({len(data)} bytes)")
    return data, ctype

ok, fail, market_hit = [], [], []
for brand_id, brand_name, url in blocks:
    if not url:
        continue
    parsed = urllib.parse.urlparse(url)
    domain = parsed.netloc if parsed.netloc else url.split("/")[0]

    saved = False
    for src_name, src_url in sources(domain):
        try:
            data, ctype = fetch(src_url)
            ext = "png"
            if "ico" in ctype or src_url.endswith(".ico"):
                ext = "ico"
            elif "svg" in ctype:
                ext = "svg"
            elif "jpeg" in ctype or "jpg" in ctype:
                ext = "jpg"
            save_path = f"logos/{brand_id}_logo.{ext}"
            with open(save_path, "wb") as out:
                out.write(data)
            tag = "  ⚠️입점몰" if any(m in domain for m in MARKET) else ""
            log(f"[성공:{src_name}] ID: {brand_id} | {brand_name}{tag}")
            ok.append((brand_id, brand_name, domain, src_name))
            if any(m in domain for m in MARKET):
                market_hit.append((brand_id, brand_name, domain))
            saved = True
            break
        except Exception:
            continue  # 다음 소스로 폴백

    if not saved:
        log(f"[실패] ID: {brand_id} | {brand_name} (도메인: {domain}) - 수동 다운로드 필요")
        fail.append((brand_id, brand_name, domain))

    time.sleep(0.3)

log(f"\n완료!  성공 {len(ok)} / 실패 {len(fail)}")

if market_hit:
    log("\n[입점몰 도메인 — 브랜드 로고 아닐 수 있음, 확인 권장]")
    for i, n, d in market_hit:
        log(f"  id {i} | {n} | {d}")

if fail:
    log("\n[수동 다운로드 필요 목록]")
    for i, n, d in fail:
        log(f"  id {i} | {n} | {d}")
