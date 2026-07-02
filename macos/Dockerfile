# DroidVM BCD-patcher — 在 Colima/Docker 容器內跑 macos/make-patches.sh。
# 只裝 hivex（改 BCD hive）+ wimlib（抽 BCD-Template）+ python3 + mount（loop 掛 ISO）。
# 這步很輕、不需 qemu/KVM/巢狀虛擬化，所以在 Mac 的容器(VM)裡跑得很快。
FROM debian:bookworm-slim
# hivexregedit 由 libwin-hivex-perl 提供（不是 libhivex-bin，後者只有 hivexget/hivexml/hivexsh）
# qemu-utils(qemu-img) + kpartx + fdisk：離線 patch 已安裝系統的 ESP BCD（03 Phase A 後用）
RUN apt-get update && apt-get install -y --no-install-recommends \
      libwin-hivex-perl wimtools python3 mount qemu-utils kpartx fdisk ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /work
