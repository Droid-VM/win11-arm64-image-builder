#!/usr/bin/env python3
# 後備：偵測 Windows 驅動簽章對話框（紅色警告橫幅）並點「Install this driver
# software anyway」。憑證已在 specialize 匯入、正常不該跳此提示；此為保險。
# 用整條橫幅取樣（非單一 pixel），對位置/雜訊較穩。
# 用法: auto-click-prompt.py <qmp.sock>
import socket, json, time, sys, re

SOCK = sys.argv[1]
PPM = "/tmp/droidvm-clk.ppm"

def connect():
    s = socket.socket(socket.AF_UNIX); s.connect(SOCK)
    f = s.makefile("rwb", buffering=0)
    f.readline()
    f.write(json.dumps({"execute": "qmp_capabilities"}).encode() + b"\n"); f.readline()
    return f

def cmd(f, c):
    f.write(json.dumps(c).encode() + b"\n"); return f.readline()

def load_ppm(path):
    d = open(path, "rb").read()
    m = re.match(rb"P6\s+(\d+)\s+(\d+)\s+(\d+)\s", d)
    if not m:
        return None, 0, 0
    return d, int(m.group(1)), m.end()

def red_band(path):
    """畫面是否有紅色警告橫幅（驅動簽章對話框）。掃多列、數紅 pixel。"""
    d, w, off = load_ppm(path)
    if d is None or w == 0:
        return False
    for y in range(110, 175):
        red = 0; base = off + y * w * 3
        for x in range(0, w, 4):
            p = base + x * 3
            if d[p] > 120 and d[p + 1] < 95 and d[p + 2] < 95:
                red += 1
        if red > w // 8:
            return True
    return False

f = None
for _ in range(120):
    try:
        f = connect(); break
    except OSError:
        time.sleep(1)
if f is None:
    sys.exit("auto-click: no qmp")

CX, CY = 340, 285                                   # "Install ... anyway" 連結中心
X = int(CX * 32767 / 800); Y = int(CY * 32767 / 600)
def send_key(qcode):
    cmd(f, {"execute": "input-send-event", "arguments": {"events": [
        {"type": "key", "data": {"down": True, "key": {"type": "qcode", "data": qcode}}}]}})
    cmd(f, {"execute": "input-send-event", "arguments": {"events": [
        {"type": "key", "data": {"down": False, "key": {"type": "qcode", "data": qcode}}}]}})

def click(x, y):
    cmd(f, {"execute": "input-send-event", "arguments": {"events": [
        {"type": "abs", "data": {"axis": "x", "value": x}},
        {"type": "abs", "data": {"axis": "y", "value": y}}]}})
    cmd(f, {"execute": "input-send-event", "arguments": {"events": [
        {"type": "btn", "data": {"button": "left", "down": True}}]}})
    cmd(f, {"execute": "input-send-event", "arguments": {"events": [
        {"type": "btn", "data": {"button": "left", "down": False}}]}})

def bright_frac(path):
    """畫面非黑位元組比例（取樣）。黑底開機畫面 ~0；藍/白 Setup 畫面高很多。"""
    d, w, off = load_ppm(path)
    if d is None or w == 0:
        return None
    nz = n = 0
    for i in range(off, len(d), 311):
        n += 1
        if d[i] > 45:
            nz += 1
    return (nz / n) if n else 0.0

def is_boot_prompt(path):
    """簡單影像識別：是不是安裝媒體的「Press any key to boot from CD or DVD」畫面
    —— 整體幾乎全黑，且上方有一條白色文字（亮白 pixel 聚集的列）。"""
    d, w, off = load_ppm(path)
    if d is None or w == 0:
        return False
    h = (len(d) - off) // (w * 3)
    if h <= 0:
        return False
    bf = bright_frac(path)
    if bf is None or bf > 0.06:                 # 太亮 -> 不是黑底開機畫面
        return False
    for y in range(int(h * 0.04), int(h * 0.42)):   # 上方找白色文字列
        bright = 0; base = off + y * w * 3
        for x in range(0, w, 3):
            p = base + x * 3
            if p + 2 < len(d) and d[p] > 170 and d[p + 1] > 170 and d[p + 2] > 170:
                bright += 1
        if bright > w // 40:
            return True
    return False

# 開機窗（全程過影像識別）：認出 CD「Press any key to boot from CD」提示才按 Enter 觸發 USB
# 開機；一旦出現非黑的 Setup 畫面就結束開機窗 —— 否則多餘 Enter 會打到「Installing Windows」
# 藍畫面的 Cancel 鈕反覆跳「Are you sure you want to quit?」。認不出提示但已黑超過 8s 時，盲按
# 一次當後備（黑畫面按 Enter 無害）。套用映像後 reboot：已過開機窗不再按鍵 -> CD 提示逾時
# fallthrough 到磁碟（不重裝迴圈）。
MIN_PRESS_SECS = 6
MAX_BOOT_SECS = 90
t0 = time.time(); pressed = 0
while time.time() - t0 < MAX_BOOT_SECS:
    bf = None
    try:
        cmd(f, {"execute": "screendump", "arguments": {"filename": PPM}})
        bf = bright_frac(PPM)
    except Exception:
        pass
    # 非黑的 Setup 畫面出現 -> 停止按鍵，避免多按打到安裝畫面（"Installing Windows" 的 Cancel）
    if bf is not None and bf > 0.06 and (time.time() - t0) > MIN_PRESS_SECS:
        break
    # 黑畫面（含只有 ~5s 的「Press any key to boot from CD」提示）-> 從 t=0 起每秒按一次 Space。
    # Space 比 Enter/ESC 安全：不會誤觸 edk2 韌體選單；對「Press any key」一樣有效。
    # 裝完後的 reboot 已過此開機窗、不再按鍵 -> CD 提示逾時 -> fallthrough 進磁碟（不重裝迴圈）。
    send_key("spc"); pressed += 1
    time.sleep(1.0)
print("auto-click: boot-press window done (%d presses)" % pressed, flush=True)

# 穩態：只在偵測到「驅動簽章紅色橫幅」時點「Install anyway」。
# 注意：不要盲送 ESC——Setup（含新版 24H2 安裝 UI）期間亂送 ESC 會取消/重置安裝。
# 憑證已在 specialize 匯入 Root+TrustedPublisher，正常不該跳此提示；此迴圈純屬保險。
# 開始菜單在首次登入彈出純屬畫面層級，不會擋 FirstLogonCommands 的自動關機。
while True:
    try:
        cmd(f, {"execute": "screendump", "arguments": {"filename": PPM}})
        if red_band(PPM):
            click(X, Y)
            print("auto-click: dismissed driver prompt", flush=True)
            time.sleep(3)
    except Exception:
        pass
    time.sleep(4)
