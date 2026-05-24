#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# Howe_Linux_sh — 外部 URL 统一管理
#
# 所有外部 URL 在此注册，模块通过变量引用
# 新增/变更 URL 只改这一个文件
#
# 安全等级说明：
#   ● 安全 (safe)    — 仅读取数据，不执行远程代码，官方/知名服务
#   ● 注意 (caution) — 读取数据，依赖第三方服务稳定性
#   ● 警告 (warn)    — 下载并执行远程脚本，需信任上游维护者
#   ● 危险 (danger)  — 下载执行 + 独立短域名/短链，存在劫持风险
#
# 操作类型说明：
#   [GET]    — 仅获取数据（HTTP 请求读取响应）
#   [EXEC]   — 下载脚本并在本地执行（curl | bash 类）
#   [DL]     — 下载文件到本地（不自动执行）
# ═══════════════════════════════════════════════════════════════════


# ┌─────────────────────────────────────────────────────────────────┐
# │ 复杂工具更新源                                                  │
# │ 脚本已存放在 lib/scripts/ 本地执行，以下 URL 仅用于更新         │
# └─────────────────────────────────────────────────────────────────┘

# yabs — 综合性能测试（fio 磁盘 + iperf3 网络 + Geekbench CPU）
# 维护者: masonr (GitHub: masonr/yet-another-bench-script)
# 安全: ● 注意 [EXEC] — GitHub 托管，本地副本 lib/scripts/yabs.sh
# 备注: 原始域名 yabs.sh 不稳定，更新源使用 GitHub raw
URL_YABS="https://raw.githubusercontent.com/masonr/yet-another-bench-script/master/yabs.sh"

# gb5 — Geekbench 5 CPU 性能测试
# 安全: ● 安全 [EXEC] — 本地重写，无远程依赖
# 备注: 原始域名 bash.icu 已失效，已重写为 lib/scripts/gb5.sh
#       直接从 cdn.geekbench.com 下载 Geekbench 二进制
URL_GB5=""

# nodequality — 融合怪综合测评（IP/流媒体/网络/性能一体化）
# 维护者: NodeQuality 团队
# 安全: ● 警告 [EXEC] — 独立域名脚本，本地副本 lib/scripts/nodequality.sh
URL_NODEQUALITY="https://run.NodeQuality.com"

# ecs-fusion — spiritysdx 融合怪 ECS 测评
# 维护者: spiritLHLS (GitHub 2.8k+ stars)
# 安全: ● 注意 [EXEC] — GitHub 托管，本地副本 lib/scripts/ecs.sh
URL_ECS_FUSION="https://raw.githubusercontent.com/spiritLHLS/ecs/raw/main/ecs.sh"


# ┌─────────────────────────────────────────────────────────────────┐
# │ Docker 安装                                                     │
# │ 脚本已存放在 lib/scripts/ 本地执行                              │
# └─────────────────────────────────────────────────────────────────┘

# Docker 国内镜像安装脚本（自动选择最快镜像源）
# 维护者: SuperManito (GitHub: SuperManito/LinuxMirrors)
# 安全: ● 注意 [EXEC] — GitHub 开源项目，本地副本 lib/scripts/docker-mirror.sh
URL_DOCKER_MIRROR="https://linuxmirrors.cn/docker.sh"

# Docker 官方安装脚本
# 维护者: Docker Inc.
# 安全: ● 安全 [EXEC] — 官方脚本，本地副本 lib/scripts/docker-official.sh
URL_DOCKER_OFFICIAL="https://get.docker.com"


# ┌─────────────────────────────────────────────────────────────────┐
# │ 安全模块                                                        │
# └─────────────────────────────────────────────────────────────────┘

# GitHub 公钥获取（拼接 /{username}.keys 获取用户 SSH 公钥）
# 维护者: GitHub Inc.
# 安全: ● 安全 [GET] — 官方 API，仅读取公开密钥
URL_GITHUB_KEYS="https://github.com"

# IPdeny 国家 IP 段数据库（拼接 /{cc}.zone 下载国家 IP 列表）
# 维护者: IPdeny.com
# 安全: ● 安全 [DL] — 纯文本 IP 列表，用于 iptables 封锁
URL_IPDENY="http://www.ipdeny.com/ipblocks/data/countries"


# ┌─────────────────────────────────────────────────────────────────┐
# │ 系统检测                                                        │
# └─────────────────────────────────────────────────────────────────┘

# ipinfo.io — IP 地理位置与 ISP 信息查询
# 维护者: ipinfo.io (知名 IP 情报服务)
# 安全: ● 安全 [GET] — 仅读取 IP 信息，不执行代码
URL_IPINFO="https://ipinfo.io"

# ipinfo.io IPv6 版本
# 安全: ● 安全 [GET] — 同上，IPv6 专用端点
URL_IPINFO_V6="https://v6.ipinfo.io"

# GitHub 连通性测试（检测 VPS 是否能访问 GitHub）
# 安全: ● 安全 [GET] — 仅测试连接，不读取内容
URL_GITHUB_CONNECTIVITY="https://github.com"


# ┌─────────────────────────────────────────────────────────────────┐
# │ ChatGPT / OpenAI 解锁检测                                       │
# │ 仅发送 HTTP GET 请求，不执行任何远程代码                         │
# └─────────────────────────────────────────────────────────────────┘

# OpenAI API 可达性测试（200/401=可达, 403=被封）
# 安全: ● 安全 [GET] — 读取 HTTP 状态码
URL_OPENAI_API="https://api.openai.com/v1/models"

# ChatGPT 网页可达性测试
# 安全: ● 安全 [GET] — 读取 HTTP 状态码
URL_OPENAI_CHAT="https://chat.openai.com/"

# OpenAI 服务状态 API（检测是否正常运营）
# 安全: ● 安全 [GET] — 读取 JSON 状态
URL_OPENAI_STATUS="https://ios.chat.openai.com/public-api/mobile/server_status/v1"


# ┌─────────────────────────────────────────────────────────────────┐
# │ 流媒体解锁检测                                                  │
# │ 仅发送 HTTP GET 请求解析地区信息，不执行远程代码                 │
# └─────────────────────────────────────────────────────────────────┘

# Netflix 解锁检测（特定影片页面，200=解锁, 404=地区限制）
# 安全: ● 安全 [GET]
URL_NETFLIX="https://www.netflix.com/title/81280792"

# YouTube Premium 解锁检测（解析页面中的地区代码）
# 安全: ● 安全 [GET]
URL_YOUTUBE_PREMIUM="https://www.youtube.com/premium"

# Disney+ 解锁检测（解析 country 字段）
# 安全: ● 安全 [GET]
URL_DISNEYPLUS="https://www.disneyplus.com/"

# TikTok 可达性检测
# 安全: ● 安全 [GET]
URL_TIKTOK="https://www.tiktok.com/"

# Spotify 地区检测（解析注册 API 返回的国家代码）
# 安全: ● 安全 [GET]
URL_SPOTIFY="https://spclient.wg.spotify.com/signup/public/v1/account"

# WebRTC IP 泄漏检测
# 安全: ● 注意 [GET] — 第三方服务，仅用于检测
URL_WEBRTC_CHECK="https://match.pstream.org/"


# ┌─────────────────────────────────────────────────────────────────┐
# │ 测速文件（10MB 下载测试）                                       │
# │ 仅用于 curl 下载测速，不执行任何代码                            │
# └─────────────────────────────────────────────────────────────────┘

# Cachefly CDN（全球 CDN，北美节点）
# 安全: ● 安全 [GET] — 纯静态文件下载
URL_SPEED_CACHEFLY="http://cachefly.cachefly.net/10mb.test"

# Tele2（瑞典运营商，欧洲节点）
# 安全: ● 安全 [GET] — 纯静态文件下载
URL_SPEED_TELE2="http://speedtest.tele2.net/10MB.zip"

# OVH（法国主机商，欧洲节点）
# 安全: ● 安全 [GET] — 纯静态文件下载
URL_SPEED_OVH="http://proof.ovh.net/files/10Mb.dat"

# Bouygues（法国运营商，欧洲节点）
# 安全: ● 安全 [GET] — 纯静态文件下载
URL_SPEED_BOUYGUES="http://bouygues.testdebit.info/10M.iso"

# OTE（希腊运营商，东南欧节点）
# 安全: ● 安全 [GET] — 纯静态文件下载
URL_SPEED_OTE="http://speedtest.ftp.otenet.gr/files/test10Mb.db"
