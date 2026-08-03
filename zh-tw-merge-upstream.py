# 上游合併輔助腳本：對 cli-translations.json 做「以 en 為鍵」的三方合併
# 規則：上游沒改的條目保留我們的繁中（含手工校對）；新增或變更的條目才跑簡轉繁
# 用法：git merge origin/main --no-commit 之後，python zh-tw-merge-upstream.py <base-commit>
# 注意：zh-tw-convert.py 的轉換只能吃「新鮮簡中原文」，禁止對已轉換的繁中重跑（會二次誤轉）
import json, subprocess, sys
from pathlib import Path
import importlib.util

# stdout 的 UTF-8 包裝交給 zh-tw-convert.py 匯入時做，這裡不可再包一次（會互相關閉緩衝區）
ROOT = Path(__file__).parent

spec = importlib.util.spec_from_file_location("ztc", ROOT / "zh-tw-convert.py")
ztc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ztc)
convert_text = ztc.convert_text

def git_show(ref, path):
    out = subprocess.run(["git", "show", f"{ref}:{path}"], cwd=ROOT,
                         capture_output=True, check=True).stdout
    return json.loads(out.decode("utf-8"))

def main():
    base_ref = sys.argv[1] if len(sys.argv) > 1 else None
    if not base_ref:
        base_ref = subprocess.run(["git", "merge-base", "HEAD", "MERGE_HEAD"], cwd=ROOT,
                                  capture_output=True, check=True).stdout.decode().strip()
    base = {e["en"]: e["zh"] for e in git_show(base_ref, "cli-translations.json")}
    theirs = git_show("MERGE_HEAD", "cli-translations.json")
    ours = {e["en"]: e["zh"] for e in git_show("HEAD", "cli-translations.json")}

    kept = converted = 0
    result = []
    for e in theirs:
        en, zh = e["en"], e["zh"]
        if en in ours and base.get(en) == zh:
            result.append({"en": en, "zh": ours[en]})
            kept += 1
        else:
            result.append({"en": en, "zh": convert_text(zh)})
            converted += 1
    out = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    (ROOT / "cli-translations.json").write_text(out, encoding="utf-8")
    (ROOT / "plugin" / "cli-translations.json").write_text(out, encoding="utf-8")
    print(f"cli-translations.json：共 {len(result)} 條，保留 {kept}、新轉 {converted}（root＋plugin 兩份）")

if __name__ == "__main__":
    main()
