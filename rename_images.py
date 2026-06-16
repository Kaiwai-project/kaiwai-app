# -*- coding: utf-8 -*-
# ============================================================
# rename_images.py
#   logos/ , backgrounds/ 의 {id}_logo.ext / {id}_bg.ext 파일명에
#   브랜드명을 삽입 → {id}_{브랜드명}_logo.ext / {id}_{브랜드명}_bg.ext
#   윈도우 금지문자(\ / : * ? " < > |)는 _ 로 치환.
# ============================================================
import os
import re
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

def log(msg):
    try:
        print(msg)
    except Exception:
        print(str(msg).encode("ascii", "replace").decode("ascii"))

# ── 1. id → 브랜드명 매핑 (객체 단위 파싱으로 정렬 보장) ─────
def load_brand_map():
    for path in ("Brand_data.csv", "index.html"):
        if os.path.exists(path):
            with open(path, "r", encoding="utf-8") as f:
                content = f.read()
            break
    else:
        raise FileNotFoundError("Brand_data.csv / index.html 을 찾을 수 없습니다.")

    starts = [m.start() for m in re.finditer(r'\{id:\s*\d+', content)]
    starts.append(len(content))
    mapping = {}
    for i in range(len(starts) - 1):
        blk = content[starts[i]:starts[i + 1]]
        bid = re.search(r'id:\s*(\d+)', blk).group(1)
        nm = re.search(r'n:\s*"([^"]+)"', blk)
        if nm:
            mapping[bid] = nm.group(1)
    return mapping

# ── 2. 윈도우 안전 파일명 ───────────────────────────────────
def sanitize(name):
    name = re.sub(r'[\\/:*?"<>|]', "_", name)   # 금지문자 → _
    name = name.strip().rstrip(". ")             # 끝의 공백/점 제거(윈도우 제약)
    return name or "_"

# ── 3. 폴더 처리 ────────────────────────────────────────────
# {id}_{kind}.{ext}  형태만 대상 (이미 이름 바뀐 건 패턴 불일치 → Skip)
PATTERN = re.compile(r"^(\d+)_(logo|bg)\.([A-Za-z0-9]+)$")

def process(folder, brand_map):
    renamed, skipped = 0, 0
    if not os.path.isdir(folder):
        log(f"[{folder}] 폴더 없음 — 건너뜀")
        return renamed, skipped
    for fname in sorted(os.listdir(folder)):
        src = os.path.join(folder, fname)
        if not os.path.isfile(src):
            continue
        m = PATTERN.match(fname)
        if not m:
            skipped += 1
            continue                       # 이미 변경됐거나 규칙 외 파일
        bid, kind, ext = m.group(1), m.group(2), m.group(3)
        name = brand_map.get(bid)
        if not name:
            log(f"  [skip] {fname} — id {bid} 매핑 없음")
            skipped += 1
            continue
        new_name = f"{bid}_{sanitize(name)}_{kind}.{ext}"
        dst = os.path.join(folder, new_name)
        if os.path.abspath(src) == os.path.abspath(dst):
            skipped += 1
            continue
        try:
            os.replace(src, dst)           # 대상 있으면 덮어씀
            log(f"  {fname}  ->  {new_name}")
            renamed += 1
        except Exception as e:
            log(f"  [실패] {fname} - {type(e).__name__}: {e}")
            skipped += 1
    return renamed, skipped

# ── 4. 실행 ─────────────────────────────────────────────────
brand_map = load_brand_map()
log(f"브랜드 매핑 {len(brand_map)}개 로드.\n")

results = {}
for folder in ("logos", "backgrounds"):
    log(f"=== {folder}/ ===")
    r, s = process(folder, brand_map)
    results[folder] = (r, s)
    log("")

log("=" * 40)
log("📊 요약")
for folder, (r, s) in results.items():
    log(f"  {folder:<12} 변경 {r}개 / 건너뜀 {s}개")
log("=" * 40)
