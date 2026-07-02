#!/usr/bin/env python3
"""
bcd-testsigning.py <bcd-file>

把一個 BCD hive 內所有 object 都加上兩個開機旗標元素：
  testsigning        = BcdLibraryBoolean_AllowPrereleaseSignatures = 16000049 = 0x01
  nointegritychecks  = BcdLibraryBoolean_DisableIntegrityChecks    = 16000048 = 0x01
對非 OS-loader 的 object 設這些元素無害（會被忽略），所以全設最省事、最穩。
testsigning 讓「以這個 BCD 開機的 WinPE/Setup」接受自簽驅動（載自簽 virtio 開機儲存驅動的關鍵）；
nointegritychecks 在現代 Win11 多半被忽略，這裡一起設純為對稱/完整（與首登 bcdedit 一致）。

只依賴 hivexregedit（Debian 套件 libwin-hivex-perl），不需要 python 的 hivex 模組。
"""
import re, subprocess, sys, tempfile, os

def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True)

def main():
    if len(sys.argv) != 2:
        sys.exit("usage: bcd-testsigning.py <bcd-file>")
    bcd = sys.argv[1]

    # 1) 匯出 \Objects 底下結構，抓出所有一階 object GUID
    exported = run("hivexregedit", "--export", bcd, r"\Objects").stdout
    guids = sorted(set(re.findall(r"^\[\\Objects\\(\{[0-9A-Fa-f-]+\})\]\s*$",
                                  exported, re.MULTILINE)))
    if not guids:
        sys.exit("找不到任何 BCD object，路徑/檔案可能不對：%s" % bcd)

    # 2) 產生 patch .reg：每個 object 都加 Elements\16000049 + \16000048 = hex:01
    #    16000049=testsigning, 16000048=nointegritychecks
    lines = ["Windows Registry Editor Version 5.00", ""]
    for g in guids:
        for elem in ("16000049", "16000048"):
            lines.append(r"[\Objects\%s\Elements\%s]" % (g, elem))
            lines.append('"Element"=hex:01')
            lines.append("")
    reg = "\n".join(lines)

    with tempfile.NamedTemporaryFile("w", suffix=".reg", delete=False) as f:
        f.write(reg)
        regpath = f.name
    try:
        run("hivexregedit", "--merge", bcd, regpath)
    finally:
        os.unlink(regpath)

    print("  testsigning + nointegritychecks 已套用到 %d 個 BCD object：%s" % (len(guids), bcd))

if __name__ == "__main__":
    main()
