#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════
# ║  AI 服务栈 一键安装脚本 V1.4 — 拆分版入口
# ║
# ║  服务：New-API / OpenWebUI / LiteLLM / Sub2API / Dify / sing-box
# ║  代理：Caddy (HTTPS) + frp (分布式穿透)
# ║  模式：All-in-One | 分布式（重服务卸载到本地 Win/Linux）
# ║
# ║  要求：Ubuntu 22.04+ / Debian 12+，root 权限
# ║
# ║  本入口只负责按依赖顺序 source 各模块；具体实现见同目录其它 .sh，
# ║  分工清单见 ai_stack/README.md。
# ╚══════════════════════════════════════════════════════════════════
set -uo pipefail   # 不使用 set -e，交互式脚本中会大量误触发退出

# 终端编辑支持（解决退格键失效问题）
if [[ -t 0 ]]; then
  _ORIG_STTY=$(stty -g 2>/dev/null || true)
  stty sane 2>/dev/null || true
  trap 'stty "$_ORIG_STTY" 2>/dev/null || true' EXIT
fi

# 定位入口所在目录（拆分模块都在这里）
_AI_STACK_ENTRY_DIR="${BASH_SOURCE[0]%/*}"
[[ "$_AI_STACK_ENTRY_DIR" == "${BASH_SOURCE[0]}" ]] && _AI_STACK_ENTRY_DIR="."
_AI_STACK_ENTRY_DIR=$(cd "$_AI_STACK_ENTRY_DIR" && pwd)

# 按依赖顺序加载（顺序很重要：core 提供 log/ask/_AI_STACK_DIR，
# 后续模块依赖前面已定义的函数和全局变量）
# shellcheck source=core.sh
source "${_AI_STACK_ENTRY_DIR}/core.sh"
# shellcheck source=detect.sh
source "${_AI_STACK_ENTRY_DIR}/detect.sh"
# shellcheck source=select.sh
source "${_AI_STACK_ENTRY_DIR}/select.sh"
# shellcheck source=base.sh
source "${_AI_STACK_ENTRY_DIR}/base.sh"
# shellcheck source=clash.sh
source "${_AI_STACK_ENTRY_DIR}/clash.sh"
# shellcheck source=compose.sh
source "${_AI_STACK_ENTRY_DIR}/compose.sh"
# shellcheck source=caddy.sh
source "${_AI_STACK_ENTRY_DIR}/caddy.sh"
# shellcheck source=services.sh
source "${_AI_STACK_ENTRY_DIR}/services.sh"
# shellcheck source=local_pkg.sh
source "${_AI_STACK_ENTRY_DIR}/local_pkg.sh"
# shellcheck source=lifecycle.sh
source "${_AI_STACK_ENTRY_DIR}/lifecycle.sh"
# shellcheck source=backup_lib.sh
source "${_AI_STACK_ENTRY_DIR}/backup_lib.sh"
# shellcheck source=backup.sh
source "${_AI_STACK_ENTRY_DIR}/backup.sh"
# shellcheck source=view.sh
source "${_AI_STACK_ENTRY_DIR}/view.sh"
# shellcheck source=main.sh
source "${_AI_STACK_ENTRY_DIR}/main.sh"

# BASH_SOURCE 守卫：独立运行时调用 main，被 source 时不执行
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
