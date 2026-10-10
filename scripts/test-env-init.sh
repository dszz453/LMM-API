#!/bin/sh
# 环境变量自动初始化测试脚本（在服务器上运行）
# 用于验证 docker-entrypoint.sh 的行为，测试完自动清理。

set -e

TEST_PORT=13001
TEST_NAME=lmm-envtest
TEST_DATA=/root/envtest-data
TEST_USER=admin
TEST_PASS='TestPass12345'
TEST_ADDR="http://192.168.31.180:$TEST_PORT"

echo "=== 清理旧环境 ==="
docker rm -f "$TEST_NAME" >/dev/null 2>&1 || true
rm -rf "$TEST_DATA"
mkdir -p "$TEST_DATA"
echo "已清理，数据目录为空"

echo
echo "=== 启动容器（纯环境变量，零手工操作）==="
docker run -d --name "$TEST_NAME" -p "$TEST_PORT:3000" \
  -e TZ=Asia/Shanghai \
  -e INIT_ROOT_USER="$TEST_USER" \
  -e INIT_ROOT_PASSWORD="$TEST_PASS" \
  -e SERVER_ADDRESS="$TEST_ADDR" \
  -e INIT_AUTO_SETUP=auto \
  -v "$TEST_DATA":/data \
  lmm-api:envtest

echo
echo "=== 等待自动初始化完成（25 秒）==="
sleep 25

echo
echo "=== entrypoint 日志 ==="
docker logs "$TEST_NAME" 2>&1 | head -40

echo
echo "=== 验证结果 ==="
echo "--- /api/setup ---"
wget -qO- "http://127.0.0.1:$TEST_PORT/api/setup" 2>/dev/null || echo "(请求失败)"
echo
echo "--- /api/status 关键字段 ---"
wget -qO- "http://127.0.0.1:$TEST_PORT/api/status" 2>/dev/null \
  | tr ',' '\n' | grep -E 'server_address|passkey_rp_id|"setup"' || echo "(请求失败)"
echo
echo "--- 登录测试 ---"
LOGIN_RESP=$(wget -qO- --header='Content-Type: application/json' \
  --post-data="{\"username\":\"$TEST_USER\",\"password\":\"$TEST_PASS\"}" \
  "http://127.0.0.1:$TEST_PORT/api/user/login" 2>/dev/null || echo '')
case "$LOGIN_RESP" in
    *'"success":true'*) echo "登录成功 ✓" ;;
    *) echo "登录失败：$LOGIN_RESP" ;;
esac
