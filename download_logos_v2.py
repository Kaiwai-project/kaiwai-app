# -*- coding: utf-8 -*-
# ============================================================
# download_logos_v2.py
#   브랜드 공식 홈페이지(japanUrl) HTML 을 직접 크롤링해서 고해상도 로고 다운로드.
#   파비콘 API 가 막혀(100바이트 미만 반환) 실패하던 문제 대응판.
#
#   탐색 우선순위:
#     1) <link rel="apple-touch-icon" href="...">   (고해상도 앱 아이콘)
#     2) <meta property="og:image" content="...">    (오픈그래프 썸네일)
#     3) <link rel="shortcut icon"> / <link rel="icon">
#   상대경로는 urljoin 으로 절대경로 변환.
#
#   데이터 출처: Brand_data.csv 가 있으면 그걸, 없으면 index.html (B 배열)을 읽음.
# ============================================================
import os
import re
import sys
import subprocess
import urllib.parse

# 콘솔이 cp949 라도 한글/일본어 출력에서 죽지 않도록 UTF-8 강제
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

def log(msg):
    try:
        print(msg)
    except Exception:
        print(str(msg).encode("ascii", "replace").decode("ascii"))

# ── 의존성 보장 (requests / beautifulsoup4) ─────────────────
def ensure(pkg, import_name=None):
    import importlib.util
    name = import_name or pkg
    if importlib.util.find_spec(name) is None:
        log(f"[설치] {pkg} 설치 중...")
        subprocess.run([sys.executable, "-m", "pip", "install", pkg], check=True)

ensure("requests")
ensure("beautifulsoup4", "bs4")

import requests
from bs4 import BeautifulSoup

# 최신 크롬 수준의 헤더 (간단한 봇 차단 우회)
HEADERS = {
    "User-Agent": ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                   "AppleWebKit/537.36 (KHTML, like Gecko) "
                   "Chrome/126.0.0.0 Safari/537.36"),
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
    "Accept-Language": "ja,en-US;q=0.9,en;q=0.8,ko;q=0.7",
    "Sec-Ch-Ua": '"Chromium";v="126", "Not.A/Brand";v="24", "Google Chrome";v="126"',
    "Sec-Ch-Ua-Mobile": "?0",
    "Sec-Ch-Ua-Platform": '"Windows"',
    "Upgrade-Insecure-Requests": "1",
}

# True 면 기존 파일이 있어도 다시 크롤링해서 성공 시 고화질로 덮어씀.
# (v1 파비콘 스크립트가 깔아둔 저화질 파일을 업그레이드하기 위해 기본 True)
# 실패하면 기존 파일은 그대로 보존(없는 것보단 나음).
SKIP_EXISTING = False

# 입점몰 도메인 — 다운로드는 시도하되 리포트에서 따로 분류
MARKETPLACES = [
    "zozo.jp", "rakuten.ne.jp", "ailand-store.jp", "runway-webstore.com",
    "stripe-club.com", "grail.bz", "dreamvs.jp", "palemoba.com",
]

# ── 1. 데이터 로드 ──────────────────────────────────────────
def load_content():
    for path in ("Brand_data.csv", "index.html"):
        if os.path.exists(path):
            with open(path, "r", encoding="utf-8") as f:
                return path, f.read()
    raise FileNotFoundError("Brand_data.csv 도 index.html 도 찾을 수 없습니다.")

src_file, content = load_content()
log(f"데이터 파일: {src_file}")

# id, 브랜드명(n), japanUrl 추출 — 반드시 "객체 단위"로 파싱.
#  (한 줄 정규식 `.*?japanUrl:"([^"]+)"` 은 japanUrl 이 빈 브랜드를 만나면
#   다음 브랜드의 URL 을 훔쳐 와서 id↔URL 정렬이 깨짐. 그래서 {id: 위치로 잘라 처리.)
starts = [m.start() for m in re.finditer(r'\{id:\s*\d+', content)]
starts.append(len(content))
all_brands = []
for i in range(len(starts) - 1):
    blk = content[starts[i]:starts[i + 1]]
    bid = re.search(r'id:\s*(\d+)', blk).group(1)
    nm = re.search(r'n:\s*"([^"]+)"', blk)
    ju = re.search(r'japanUrl:\s*"([^"]*)"', blk)
    all_brands.append((bid, nm.group(1) if nm else "?", ju.group(1) if ju else ""))

no_url = [(b, n) for b, n, u in all_brands if not u.strip()]
blocks = [(b, n, u) for b, n, u in all_brands if u.strip()]
log(f"전체 {len(all_brands)}개 | 홈페이지 있어 크롤링 {len(blocks)}개 | japanUrl 비어있음 {len(no_url)}개\n")

os.makedirs("logos", exist_ok=True)

# ── 2. HTML 에서 로고 이미지 URL 추출 ───────────────────────
def find_logo_url(html, base_url):
    soup = BeautifulSoup(html, "html.parser")

    # 1순위: apple-touch-icon (sizes 가 큰 것 우선)
    candidates = soup.find_all("link", rel=lambda v: v and "apple-touch-icon" in " ".join(v).lower())
    def icon_size(tag):
        s = (tag.get("sizes") or "").lower()
        m = re.match(r"(\d+)", s)
        return int(m.group(1)) if m else 0
    candidates.sort(key=icon_size, reverse=True)
    for tag in candidates:
        if tag.get("href"):
            return urllib.parse.urljoin(base_url, tag["href"]), "apple-touch-icon"

    # 2순위: og:image
    og = soup.find("meta", property="og:image") or soup.find("meta", attrs={"name": "og:image"})
    if og and og.get("content"):
        return urllib.parse.urljoin(base_url, og["content"]), "og:image"

    # 3순위: shortcut icon / icon
    for tag in soup.find_all("link", rel=lambda v: v and "icon" in " ".join(v).lower()):
        if tag.get("href"):
            return urllib.parse.urljoin(base_url, tag["href"]), "icon"

    return None, None

def ext_from(url, content_type):
    path = urllib.parse.urlparse(url).path.lower()
    for e in (".png", ".jpg", ".jpeg", ".svg", ".webp", ".ico", ".gif"):
        if path.endswith(e):
            return e.lstrip(".")
    ct = (content_type or "").lower()
    if "png" in ct: return "png"
    if "jpeg" in ct or "jpg" in ct: return "jpg"
    if "svg" in ct: return "svg"
    if "webp" in ct: return "webp"
    if "x-icon" in ct or "vnd.microsoft.icon" in ct: return "ico"
    return "png"

EXTS = ("png", "jpg", "jpeg", "svg", "webp", "ico", "gif")

def existing_files(brand_id):
    return [f"logos/{brand_id}_logo.{e}" for e in EXTS if os.path.exists(f"logos/{brand_id}_logo.{e}")]

def remove_existing(brand_id):
    # 확장자 중복(예: 56_logo.png + 56_logo.jpg) 방지를 위해 기존 파일 제거
    for p in existing_files(brand_id):
        try:
            os.remove(p)
        except Exception:
            pass

# ── 3. 메인 루프 ────────────────────────────────────────────
ok, fail, market = [], [], []
for brand_id, brand_name, url in blocks:
    domain = urllib.parse.urlparse(url).netloc or url.split("/")[0]
    is_market = any(m in url for m in MARKETPLACES)

    if SKIP_EXISTING and existing_files(brand_id):
        log(f"[건너뜀] ID: {brand_id} | {brand_name} (이미 있음)")
        ok.append((brand_id, brand_name, domain, "skip"))
        if is_market:
            market.append((brand_id, brand_name, domain))
        continue

    try:
        # (a) 홈페이지 HTML 받기
        resp = requests.get(url, headers=HEADERS, timeout=10, allow_redirects=True)
        resp.raise_for_status()

        # (b) 로고 URL 파싱 (못 찾으면 /favicon.ico 폴백)
        logo_url, how = find_logo_url(resp.text, resp.url)
        if not logo_url:
            p = urllib.parse.urlparse(resp.url)
            logo_url = f"{p.scheme}://{p.netloc}/favicon.ico"
            how = "favicon.ico"

        # (c) 로고 이미지 다운로드
        img = requests.get(logo_url, headers=HEADERS, timeout=10, allow_redirects=True)
        img.raise_for_status()
        data = img.content
        if not data or len(data) < 100:
            raise ValueError(f"이미지가 너무 작음 ({len(data)} bytes)")

        ext = ext_from(logo_url, img.headers.get("Content-Type"))
        # 성공했을 때만 기존 파일 제거 후 새로 저장 (실패 시 기존 파일 보존)
        remove_existing(brand_id)
        save_path = f"logos/{brand_id}_logo.{ext}"
        with open(save_path, "wb") as out:
            out.write(data)

        tag = "  ⚠️입점몰" if is_market else ""
        log(f"[성공:{how}] ID: {brand_id} | {brand_name}{tag} -> {save_path} ({len(data)//1024}KB)")
        ok.append((brand_id, brand_name, domain, how))
        if is_market:
            market.append((brand_id, brand_name, domain))

    except Exception as e:
        log(f"[실패] ID: {brand_id} | {brand_name} (도메인: {domain}) - {type(e).__name__}: {e}")
        fail.append((brand_id, brand_name, domain))

# ── 4. 리포트 ───────────────────────────────────────────────
log("\n" + "=" * 50)
log(f"📊 결과 요약   성공 {len(ok)} / 실패 {len(fail)}  (총 {len(blocks)})")
log("=" * 50)

if fail:
    log("\n❌ [실패한 브랜드 — 수동 다운로드 필요]")
    for i, n, d in fail:
        log(f"  id {i:>2} | {n} | {d}")

if market:
    log("\n⚠️ [입점몰 도메인 감지 — 수동 교체 권장]")
    for i, n, d in market:
        log(f"  id {i:>2} | {n} | {d}")

if no_url:
    log("\n⚪ [코드에 japanUrl 이 비어있어 시도 불가 — index.html 에 주소 추가 필요]")
    for i, n in no_url:
        log(f"  id {i:>2} | {n}")

log("\n🎉 완료. logos/ 폴더를 확인하세요.")
