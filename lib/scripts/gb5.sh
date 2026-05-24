#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# gb5.sh — Geekbench 5 CPU 性能测试
#
# 功能：下载 Geekbench 5 并执行 CPU 基准测试
# 原始来源：bash.icu/gb5（域名已失效，本地重写）
# ═══════════════════════════════════════════════════════════════════
set -e

WORK_DIR="/tmp/geekbench5"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# 检测架构
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  GB_ARCH="x86_64" ;;
  aarch64) GB_ARCH="aarch64" ;;
  *)       echo "不支持的架构: $ARCH"; exit 1 ;;
esac

GB_URL="https://cdn.geekbench.com/Geekbench-5.5.1-Linux.tar.gz"
GB_DIR="Geekbench-5.5.1-Linux"

echo "=== Geekbench 5 CPU 性能测试 ==="
echo "架构: $ARCH"
echo ""

# 下载
if [[ ! -f "$GB_DIR/geekbench5" ]]; then
  echo "下载 Geekbench 5 ..."
  curl -sL --max-time 120 "$GB_URL" -o geekbench5.tar.gz
  tar -xzf geekbench5.tar.gz
  rm -f geekbench5.tar.gz
fi

# 运行
echo "运行单核测试..."
echo "运行多核测试..."
echo ""

"$GB_DIR/geekbench5" --no-upload 2>&1 || true

# 解析结果
RESULT_FILE=$(find . -name "result*.html" -newer "$GB_DIR/geekbench5" 2>/dev/null | head -1)
if [[ -n "$RESULT_FILE" ]]; then
  SINGLE=$(grep -oP 'Single-Core Score.*?<span class="score">\K[\d,]+' "$RESULT_FILE" 2>/dev/null | head -1 | tr -d ',')
  MULTI=$(grep -oP 'Multi-Core Score.*?<span class="score">\K[\d,]+' "$RESULT_FILE" 2>/dev/null | head -1 | tr -d ',')
  echo ""
  echo "=== 结果 ==="
  [[ -n "$SINGLE" ]] && echo "单核: $SINGLE"
  [[ -n "$MULTI" ]]  && echo "多核: $MULTI"
fi

# 清理
cd /
rm -rf "$WORK_DIR"
