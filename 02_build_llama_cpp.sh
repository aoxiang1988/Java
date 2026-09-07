#!/usr/bin/env bash
# ============================================================
# 编译 llama.cpp 的 llama-server（CPU 基线版，aarch64 Linux）
#
# 用法:
#   ./02_build_llama_cpp.sh onboard   # 在开发板 Linux 上原生编译（板上有 gcc/cmake 时推荐）
#   ./02_build_llama_cpp.sh cross     # 在 x86 PC 上交叉编译（产物为静态单文件，scp 上板即可）
#
# 依赖（Ubuntu/Debian 系）:
#   onboard: sudo apt install -y git cmake build-essential
#   cross:   sudo apt install -y git cmake gcc-aarch64-linux-gnu g++-aarch64-linux-gnu
#
# 阶段 2（Adreno OpenCL）/ 阶段 3（Hexagon NPU）需要额外 SDK，
# 见 README.md「进阶加速路线」与 llama.cpp 官方 snapdragon 文档。
# ============================================================
set -euo pipefail

MODE="${1:-onboard}"
SRC_DIR="$(pwd)/llama.cpp"

if [ ! -d "${SRC_DIR}" ]; then
  echo ">>> 克隆 llama.cpp"
  git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "${SRC_DIR}"
  # 国内网络不畅可用镜像（同步可能滞后一两天）:
  # git clone --depth 1 https://gitee.com/mirrors/llama.cpp.git "${SRC_DIR}"
fi

CMAKE_ARGS=(
  -S "${SRC_DIR}"
  -B "${SRC_DIR}/build"
  -DCMAKE_BUILD_TYPE=Release
  # 静态链接：产出一个独立 llama-server 可执行文件，免去板子上带一堆 .so
  -DBUILD_SHARED_LIBS=OFF
  # 服务不联网下载模型（用本地 GGUF），规避 libcurl 依赖
  -DLLAMA_CURL=OFF
)

if [ "${MODE}" = "cross" ]; then
  CMAKE_ARGS+=(
    -DCMAKE_SYSTEM_NAME=Linux
    -DCMAKE_SYSTEM_PROCESSOR=aarch64
    -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc
    -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++
    # 交叉编译无法 -march=native，必须关闭
    -DGGML_NATIVE=OFF
    # 车机 SoC（SA8797，ARMv8.6 级核心，含 asimddp/i8mm/bf16）。
    # 不加 march 时 gcc 按 aarch64 基线编译，Q4_K 量化矩阵乘走不到
    # dotprod 指令，实测生成速度只有 ~0.2-0.4 tok/s；加上后可快数倍。
    # 目标核为 ARMv8.6，gcc 10.1+ 支持；若目标更老可退回 armv8.2-a+dotprod+fp16
    -DCMAKE_C_FLAGS="-march=armv8.6-a"
    -DCMAKE_CXX_FLAGS="-march=armv8.6-a"
  )
fi

echo ">>> CMake 配置 (${MODE})"
cmake "${CMAKE_ARGS[@]}"

echo ">>> 编译（$(nproc) 线程）"
cmake --build "${SRC_DIR}/build" --config Release -j"$(nproc)" --target llama-server

BIN="${SRC_DIR}/build/bin/llama-server"
echo
echo ">>> 编译完成: ${BIN}"
file "${BIN}"
echo
if [ "${MODE}" = "cross" ]; then
  echo "部署到车机（在存有二进制的 Windows 机上执行）:"
  echo "  adb -s 192.168.1.1:5555 push ${BIN} /data/qwen-vl/bin/llama-server.new"
  echo "  adb -s 192.168.1.1:5555 shell \"mv /data/qwen-vl/bin/llama-server.new /data/qwen-vl/bin/llama-server; chmod +x /data/qwen-vl/bin/llama-server; chcon system_u:object_r:bin_t:s0 /data/qwen-vl/bin/llama-server; systemctl restart llama-server\""
  echo "  # 上车后验证指令集是否生效: journalctl -u llama-server | grep -i dotprod （应看到相关特性被启用）"
else
  echo "安装到服务目录:"
  echo "  adb shell mkdir -p /data/qwen-vl/bin && adb push ${BIN} /data/qwen-vl/bin/llama-server"
  echo "  # 车机根分区只读，统一部署到 /data/qwen-vl（见 llama-server-car.service）"
fi
