# 簡轉繁（台灣慣用語）轉換腳本：OpenCC s2twp + 詞彙修正表
# 用法：python zh-tw-convert.py [--scan]  （--scan 只輸出可疑用語報告，不寫檔）
import json, re, sys, io
from pathlib import Path
import opencc

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")
ROOT = Path(__file__).parent
CC = opencc.OpenCC("s2twp")
HAN_RUN = re.compile(r"[㐀-鿿豈-﫿]+")

# OpenCC 轉完後再套的台灣詞彙修正表（處理 OpenCC 抓不到的用語差異與 OpenCC 怪譯）
# 順序有意義：長詞／特定語境先換，通用詞後換
PROTECT = ["自檢通過", "校驗通過", "驗證通過", "測試通過", "檢查通過", "未通過", "不通過"]
FIXES = [
    # 語言指示（本外掛的核心語義修改）
    ("使用簡體中文回覆", "使用繁體中文（台灣）回覆"),
    ("中文（簡體）", "繁體中文（台灣）"),
    ("簡體中文", "繁體中文"),
    # 特定語境優先
    ("擴充套件推理", "延伸推理"),
    ("請訪問：", "請前往："),
    ("新克隆", "新副本"),
    ("退出碼", "結束代碼"),
    ("移動應用", "行動版 App"),
    ("時出錯", "時發生錯誤"),
    ("出錯", "時發生錯誤"),
    # 大陸用語 → 台灣用語
    ("二維碼", "QR Code"),
    ("包名", "套件名稱"),
    ("獲取", "取得"),
    ("構建", "建置"),
    ("流式", "串流"),
    ("定製", "客製"),
    ("顯式", "明確"),
    ("隱式", "隱含"),
    ("導航", "導覽"),
    ("窗口", "視窗"),
    ("創建", "建立"),
    ("退出", "離開"),
    ("通過", "透過"),
    ("反饋", "回饋"),
    ("質量", "品質"),
    ("用戶", "使用者"),
    ("發送", "傳送"),
    ("克隆", "複製"),
    # OpenCC s2twp 怪譯修正
    ("許可權", "權限"),
    ("引數", "參數"),
    ("當前", "目前"),
    ("會話", "工作階段"),
    ("指令碼", "腳本"),
    ("倉庫", "儲存庫"),
    ("檢測", "偵測"),
    ("計劃", "計畫"),
    ("列印", "輸出"),
    ("鑰匙串", "鑰匙圈"),
    ("擴充套件", "擴充功能"),
    ("後臺", "背景"),
    ("訪問", "存取"),
    ("令牌", "權杖"),
    ("回撥", "回呼"),
    ("控制檯", "主控台"),
    ("本地化", "在地化"),
    ("本地", "本機"),
    ("全域性", "全域"),
    ("自定義", "自訂"),
    ("跟蹤", "追蹤"),
    ("回退", "回溯"),
    ("跑偏", "偏離"),
    ("沙箱", "沙盒"),
    ("響應", "回應"),
    ("超時", "逾時"),
    ("註釋", "註解"),
    ("撤銷", "復原"),
    ("滾動", "捲動"),
    ("懸停", "游標停留"),
    ("拖拽", "拖曳"),
    ("賬號", "帳號"),
    ("賬戶", "帳戶"),
    ("臺", "台"),
    # 反向救回：「撤銷→復原」是給 undo 用的，token/憑證的 revocation 要維持「撤銷」
    ("復原權杖", "撤銷權杖"),
    ("token 復原", "token 撤銷"),
]

def convert_text(text: str) -> str:
    # 只轉換中文字元連續段，ASCII／佔位符完全不動
    out = HAN_RUN.sub(lambda m: CC.convert(m.group(0)), text)
    for i, word in enumerate(PROTECT):
        out = out.replace(word, f"\x00{i}\x00")
    for old, new in FIXES:
        out = out.replace(old, new)
    for i, word in enumerate(PROTECT):
        out = out.replace(f"\x00{i}\x00", word)
    return out

def convert_json_file(path: Path, transform):
    data = json.loads(path.read_text(encoding="utf-8"))
    transform(data)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"[json] {path.relative_to(ROOT)}")

def convert_code_file(path: Path):
    text = path.read_text(encoding="utf-8")
    new = convert_text(text)
    if new != text:
        path.write_text(new, encoding="utf-8", newline="")
        print(f"[code] {path.relative_to(ROOT)}")

def main():
    # 1. 主翻譯表（root 版轉完複製到 plugin 版，兩份原本 md5 相同）
    trans_path = ROOT / "cli-translations.json"
    data = json.loads(trans_path.read_text(encoding="utf-8"))
    for item in data:
        item["zh"] = convert_text(item["zh"])
    out = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    trans_path.write_text(out, encoding="utf-8")
    (ROOT / "plugin" / "cli-translations.json").write_text(out, encoding="utf-8")
    print(f"[json] cli-translations.json（{len(data)} 條，root＋plugin 兩份）")

    # 2. spinner 動詞
    convert_json_file(ROOT / "verbs" / "zh-CN.json", lambda d: d.update(verbs=[convert_text(v) for v in d["verbs"]]))
    # 3. 提示
    def fix_tips(d):
        for t in d["tips"]:
            t["text"] = convert_text(t["text"])
    convert_json_file(ROOT / "tips" / "zh-CN.json", fix_tips)
    # 4. 外掛描述（顯示在 /plugin 介面）
    for rel in [".claude-plugin/marketplace.json", "plugin/.claude-plugin/plugin.json", "plugin/manifest.json"]:
        p = ROOT / rel
        p.write_text(convert_text(p.read_text(encoding="utf-8")), encoding="utf-8", newline="")
        print(f"[json] {rel}")
    # 5. hook 程式檔（每次會話會執行、訊息使用者看得到）
    for rel in ["session-start.js", "notification.js", "session-start.ps1", "notification.ps1", "session-start", "notification"]:
        p = ROOT / "plugin" / "hooks" / rel
        if p.exists():
            convert_code_file(p)

def scan():
    # 掃描轉換後殘留的可疑用語，逐條列出讓人工審
    suspects = r"用戶|設置|創建|打開|運行|登錄|註銷|支持|刷新|退出|代碼|調試|反饋|窗口|命令行|進程|線程|網關|通過|會話|信息|軟件|服務器|光標|智能|視頻|音頻|質量|優先級|內存|硬盤|字符|字段|拷貝|粘貼|默認|缺省|網絡|鼠標|回車|激活|交互|授權碼|全局|遍歷|發送|重命名|其他|其它|操作系統"
    pat = re.compile(suspects)
    hits = {}
    for item in json.loads((ROOT / "cli-translations.json").read_text(encoding="utf-8")):
        for m in set(pat.findall(item["zh"])):
            hits.setdefault(m, []).append(item["zh"][:60])
    for rel in ["verbs/zh-CN.json", "tips/zh-CN.json"]:
        text = (ROOT / rel).read_text(encoding="utf-8")
        for m in set(pat.findall(text)):
            hits.setdefault(m, []).append(f"<{rel}>")
    for word in sorted(hits, key=lambda w: -len(hits[w])):
        print(f"\n### {word}（{len(hits[word])} 處）")
        for ex in hits[word][:8]:
            print(f"  - {ex}")

if __name__ == "__main__":
    scan() if "--scan" in sys.argv else main()
