# -*- coding: utf-8 -*-
# ============================================================
# download_images_v3.py
#   DuckDuckGo 이미지 검색으로
#     (1) 누락/실패/입점몰 로고 보완  -> logos/{id}_logo.{ext}
#     (2) 대표 스타일링 이미지(bgImg) 수집 -> backgrounds/{id}_bg.jpg
#
#   ⚠️ 검색 결과 이미지는 브랜드 불일치/저작권 이슈가 있을 수 있음 → 사람이 검수 전제.
#   ⚠️ duckduckgo 검색은 rate-limit 이 잦음 → sleep/예외처리로 방어.
# ============================================================
import os
import re
import sys
import time
import random
import subprocess
import urllib.parse

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

def log(msg):
    try:
        print(msg, flush=True)
    except Exception:
        print(str(msg).encode("ascii", "replace").decode("ascii"), flush=True)

# ── 의존성 보장 ─────────────────────────────────────────────
def ensure(pip_name, import_name=None):
    import importlib.util
    if importlib.util.find_spec(import_name or pip_name) is None:
        log(f"[설치] {pip_name} ...")
        subprocess.run([sys.executable, "-m", "pip", "install", pip_name], check=True)

ensure("requests")
# 신버전 패키지명은 ddgs, 구버전은 duckduckgo-search
try:
    import importlib.util
    if importlib.util.find_spec("ddgs") is None and importlib.util.find_spec("duckduckgo_search") is None:
        ensure("ddgs")
except Exception:
    ensure("ddgs")

import requests
try:
    from ddgs import DDGS            # 신버전
except Exception:
    from duckduckgo_search import DDGS  # 구버전

HEADERS = {
    "User-Agent": ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                   "AppleWebKit/537.36 (KHTML, like Gecko) "
                   "Chrome/126.0.0.0 Safari/537.36"),
}

MARKETPLACES = [
    "zozo.jp", "rakuten.ne.jp", "ailand-store.jp", "runway-webstore.com",
    "stripe-club.com", "grail.bz", "dreamvs.jp", "palemoba.com",
]
EXTS = ("png", "jpg", "jpeg", "svg", "webp", "ico", "gif")

# ── 데이터 파싱 (객체 단위 — id↔필드 정렬 보장) ──────────────
with open("index.html", "r", encoding="utf-8") as f:
    content = f.read()
starts = [m.start() for m in re.finditer(r'\{id:\s*\d+', content)]
starts.append(len(content))
brands = []
for i in range(len(starts) - 1):
    blk = content[starts[i]:starts[i + 1]]
    bid = re.search(r'id:\s*(\d+)', blk).group(1)
    nm = re.search(r'n:\s*"([^"]+)"', blk)
    ju = re.search(r'japanUrl:\s*"([^"]*)"', blk)
    brands.append((bid, nm.group(1) if nm else "?", ju.group(1) if ju else ""))
log(f"브랜드 {len(brands)}개 로드.\n")

os.makedirs("logos", exist_ok=True)
os.makedirs("backgrounds", exist_ok=True)

def logo_files(bid):
    return [f"logos/{bid}_logo.{e}" for e in EXTS if os.path.exists(f"logos/{bid}_logo.{e}")]

def is_market(url):
    return any(m in url for m in MARKETPLACES)

# ── DDG 이미지 검색 (rate-limit 방어) ───────────────────────
def search_images(query, max_results=12):
    for attempt in range(3):
        try:
            with DDGS() as d:
                try:
                    return list(d.images(query, max_results=max_results))
                except TypeError:
                    return list(d.images(keywords=query, max_results=max_results))
        except Exception as e:
            wait = 5 * (attempt + 1)
            log(f"   (검색 재시도 {attempt+1}/3, {wait}s 대기) {type(e).__name__}")
            time.sleep(wait)
    return []

def download(url, save_path, min_bytes=2000):
    r = requests.get(url, headers=HEADERS, timeout=12, allow_redirects=True)
    r.raise_for_status()
    data = r.content
    if not data or len(data) < min_bytes:
        raise ValueError(f"too small ({len(data)} bytes)")
    with open(save_path, "wb") as out:
        out.write(data)
    return len(data)

def ext_of(url):
    p = urllib.parse.urlparse(url).path.lower()
    for e in ("png", "jpg", "jpeg", "webp", "gif"):
        if p.endswith("." + e):
            return e
    return "jpg"

def to_int(v):
    # DDG 결과의 width/height 가 문자열로 오는 경우 대비
    try:
        return int(v)
    except (TypeError, ValueError):
        return 0

# ============================================================
# 타겟 1 — 로고 보완
#   대상: 파일 없음 OR 저화질(<3KB) OR 입점몰 도메인
# ============================================================
log("=" * 50)
log("타겟 1: 로고 보완 (DDG '브랜드명 logo')")
log("=" * 50)
logo_ok, logo_skip = [], []
for bid, name, url in brands:
    files = logo_files(bid)
    small = files and os.path.getsize(files[0]) < 3000
    # 파일 없음 OR 저화질만 대상. (입점몰은 이번 실행에서 이미 검색로고로 교체됨 → 재실행 시 중복 방지)
    need = (not files) or small
    if not need:
        logo_skip.append(bid)
        continue

    found = False
    for q in (f"{name} logo", f"{name} brand logo"):
        results = search_images(q, 15)
        for r in results:
            img = r.get("image") or r.get("url")
            if not img:
                continue
            try:
                # 로고는 너무 큰 배너보다 적당한 것 — 그냥 첫 유효 이미지 채택
                for p in logo_files(bid):
                    os.remove(p)
                ext = ext_of(img)
                size = download(img, f"logos/{bid}_logo.{ext}", min_bytes=2000)
                log(f"[로고✓] id {bid:>2} | {name}  ({size//1024}KB)  <- {q}")
                logo_ok.append(bid)
                found = True
                break
            except Exception:
                continue
        if found:
            break
        time.sleep(1.0)
    if not found:
        log(f"[로고✗] id {bid:>2} | {name} - 검색/다운로드 실패")
    time.sleep(random.uniform(1.2, 2.2))  # rate-limit 방어

# ============================================================
# 타겟 2 — 대표 스타일링 이미지(bgImg) 수집 (전체, 이미 있으면 skip)
# ============================================================
log("\n" + "=" * 50)
log("타겟 2: 대표 스타일링 이미지 (DDG 'lookbook/코디')")
log("=" * 50)
bg_ok, bg_skip = [], []
for bid, name, url in brands:
    save_path = f"backgrounds/{bid}_bg.jpg"
    if os.path.exists(save_path):
        bg_skip.append(bid)
        continue

    found = False
    for q in (f"{name} lookbook", f"{name} コーディネート", f"{name} 코디"):
        results = search_images(q, 20)
        # 세로 비율 좋은 것 우선 (height > width), 해상도 적당(>=600 높이) 우선
        def score(r):
            w = to_int(r.get("width"))
            h = to_int(r.get("height"))
            portrait = 1 if (w > 0 and h >= w) else 0
            return (portrait, min(h, 2000))
        for r in sorted(results, key=score, reverse=True):
            img = r.get("image") or r.get("url")
            if not img:
                continue
            try:
                download(img, save_path, min_bytes=8000)  # 배경은 더 큰 이미지 요구
                w = r.get("width"); h = r.get("height")
                log(f"[배경✓] id {bid:>2} | {name}  ({w}x{h})  <- {q}")
                bg_ok.append(bid)
                found = True
                break
            except Exception:
                continue
        if found:
            break
        time.sleep(1.0)
    if not found:
        log(f"[배경✗] id {bid:>2} | {name} - 검색/다운로드 실패")
    time.sleep(random.uniform(1.2, 2.2))

# ── 리포트 ──────────────────────────────────────────────────
log("\n" + "=" * 50)
log("📊 요약")
log(f"  로고 보완: 성공 {len(logo_ok)}개 (이미 양호해서 건너뜀 {len(logo_skip)}개)")
log(f"  배경 수집: 성공 {len(bg_ok)}개 (이미 있어 건너뜀 {len(bg_skip)}개)")
log("=" * 50)
log("\n⚠️ 검색 기반 이미지는 브랜드 불일치/저작권 가능성 있음 → logos/ 와 backgrounds/ 를 직접 검수하세요.")
