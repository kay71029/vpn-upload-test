#!/bin/bash

# ============================================================
# Hysteria 2 / OpenVPN GitHub Upload Test
# macOS Bash compatible
# ============================================================

set -u

# ------------------------------------------------------------
# 基本設定
# ------------------------------------------------------------

TEST_SIZE_MIB=50
TEST_COUNT=3
TEST_INTERVAL=60

RESULT_DIR="./results"
TEST_FILE_DIR="./upload-test-files"

GITHUB_REMOTE="origin"
GITHUB_BRANCH="main"

HYSTERIA_PROXY="socks5h://127.0.0.1:1080"
IP_CHECK_URL="https://api.ipify.org"

MODE="${MODE:-}"
PROFILE="${PROFILE:-original}"

# ------------------------------------------------------------
# 顯示使用方法
# ------------------------------------------------------------

show_usage() {
    echo "使用方法："
    echo
    echo "Hysteria 2："
    echo "MODE=hysteria PROFILE=original ./github-upload-test.sh"
    echo
    echo "OpenVPN："
    echo "MODE=openvpn PROFILE=original ./github-upload-test.sh"
    echo
    echo "支援的 PROFILE："
    echo "original"
    echo "loss5"
    echo "loss10"
    echo "latency150"
    echo "latency300"
}

# ------------------------------------------------------------
# 檢查參數
# ------------------------------------------------------------

check_arguments() {
    case "${MODE}" in
        hysteria|openvpn)
            ;;
        *)
            echo "錯誤：MODE 必須是 hysteria 或 openvpn"
            show_usage
            exit 1
            ;;
    esac

    case "${PROFILE}" in
        original|loss5|loss10|latency150|latency300)
            ;;
        *)
            echo "錯誤：不支援的 PROFILE：${PROFILE}"
            show_usage
            exit 1
            ;;
    esac
}

# ------------------------------------------------------------
# 檢查執行環境
# ------------------------------------------------------------

check_environment() {
    if ! command -v git >/dev/null 2>&1; then
        echo "錯誤：找不到 git"
        exit 1
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "錯誤：找不到 curl"
        exit 1
    fi

    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "錯誤：目前目錄不是 Git Repository"
        exit 1
    fi

    if ! git remote get-url "${GITHUB_REMOTE}" \
        | grep -q '^https://github.com/'; then
        echo "錯誤：GitHub Remote 必須使用 HTTPS"
        git remote -v
        exit 1
    fi

    mkdir -p "${RESULT_DIR}"
    mkdir -p "${TEST_FILE_DIR}"
}

# ------------------------------------------------------------
# 確認目前沒有尚未提交的異動
# ------------------------------------------------------------

check_git_status() {
    if [ -n "$(git status --porcelain)" ]; then
        echo "錯誤：Repository 目前存在尚未提交的異動。"
        echo
        git status --short
        echo
        echo "請先提交、移走或處理既有檔案後再執行。"
        exit 1
    fi
}

# ------------------------------------------------------------
# 取得出口 IP
# ------------------------------------------------------------

get_exit_ip() {
    if [ "${MODE}" = "hysteria" ]; then
        curl -4 -sS \
            --connect-timeout 15 \
            --max-time 30 \
            --proxy "${HYSTERIA_PROXY}" \
            "${IP_CHECK_URL}"
    else
        curl -4 -sS \
            --connect-timeout 15 \
            --max-time 30 \
            "${IP_CHECK_URL}"
    fi
}

# ------------------------------------------------------------
# 產生隨機測試檔案
# ------------------------------------------------------------

create_test_file() {
    RUN_NUMBER="$1"
    TIMESTAMP="$2"

    TEST_FILE="${TEST_FILE_DIR}/${MODE}-${PROFILE}-${TIMESTAMP}-run${RUN_NUMBER}.bin"

    dd if=/dev/urandom \
        of="${TEST_FILE}" \
        bs=1m \
        count="${TEST_SIZE_MIB}" \
        status=none

    if [ ! -f "${TEST_FILE}" ]; then
        echo "錯誤：測試檔案建立失敗"
        exit 1
    fi
}

# ------------------------------------------------------------
# 執行 Git Push
# ------------------------------------------------------------

run_git_push() {
    if [ "${MODE}" = "hysteria" ]; then
        git \
            -c http.proxy="${HYSTERIA_PROXY}" \
            -c https.proxy="${HYSTERIA_PROXY}" \
            push "${GITHUB_REMOTE}" "${GITHUB_BRANCH}"
    else
        git push "${GITHUB_REMOTE}" "${GITHUB_BRANCH}"
    fi
}

# ------------------------------------------------------------
# 執行單次測試
# ------------------------------------------------------------

run_single_test() {
    RUN_NUMBER="$1"
    TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"

    create_test_file "${RUN_NUMBER}" "${TIMESTAMP}"

    git add "${TEST_FILE}"

    git commit \
        -m "${MODE} ${PROFILE} upload test ${RUN_NUMBER}"

    START_EPOCH="$(date +%s)"

    run_git_push
    PUSH_EXIT="$?"

    END_EPOCH="$(date +%s)"
    ELAPSED="$((END_EPOCH - START_EPOCH))"

    if [ "${ELAPSED}" -le 0 ]; then
        ELAPSED=1
    fi

    SPEED_MBPS="$(
        awk \
            -v size="${TEST_SIZE_MIB}" \
            -v seconds="${ELAPSED}" \
            'BEGIN {
                printf "%.2f", (size * 8) / seconds
            }'
    )"

    NOW="$(date '+%Y-%m-%d %H:%M:%S')"

    if [ "${PUSH_EXIT}" -eq 0 ]; then
        STATUS="成功"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        STATUS="失敗"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi

    echo "第 $(printf '%02d' "${RUN_NUMBER}") 次 | ${NOW} | ${STATUS} | EXIT=${PUSH_EXIT} | SIZE=${TEST_SIZE_MIB} MiB | SPEED=${SPEED_MBPS} Mbps | TIME=${ELAPSED} s" \
        | tee -a "${LOG_FILE}"
}

# ------------------------------------------------------------
# 產生摘要
# ------------------------------------------------------------

create_summary() {
    SUCCESS_RATE="$(
        awk \
            -v success="${SUCCESS_COUNT}" \
            -v total="${TEST_COUNT}" \
            'BEGIN {
                printf "%.2f", success / total * 100
            }'
    )"

    {
        echo "================================================"
        echo "測試完成"
        echo "總測試次數：${TEST_COUNT}"
        echo "成功次數：${SUCCESS_COUNT}"
        echo "失敗次數：${FAILED_COUNT}"
        echo "成功率：${SUCCESS_RATE}%"
        echo "結束時間：$(date '+%Y-%m-%d %H:%M:%S')"
        echo "Log：${LOG_FILE}"
        echo "================================================"
    } | tee -a "${LOG_FILE}"
}

# ------------------------------------------------------------
# 主程式
# ------------------------------------------------------------

main() {
    check_arguments
    check_environment
    check_git_status

    LOG_TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
    LOG_FILE="${RESULT_DIR}/${LOG_TIMESTAMP}-${MODE}-${PROFILE}-github-upload.log"

    SUCCESS_COUNT=0
    FAILED_COUNT=0

    EXIT_IP="$(get_exit_ip)"

    if [ -z "${EXIT_IP}" ]; then
        echo "錯誤：無法取得出口 IP"
        exit 1
    fi

    {
        echo "========== GitHub 上傳測試 =========="
        echo "測試模式：${MODE}"
        echo "測試情境：${PROFILE}"
        echo "出口 IP：${EXIT_IP}"
        echo "測試檔案：每次 ${TEST_SIZE_MIB} MiB"
        echo "重複次數：${TEST_COUNT}"
        echo "測試間隔：${TEST_INTERVAL} 秒"
        echo "GitHub Remote：$(git remote get-url "${GITHUB_REMOTE}")"
        echo "GitHub Branch：${GITHUB_BRANCH}"
        echo "開始時間：$(date '+%Y-%m-%d %H:%M:%S')"
        echo "================================================"
    } | tee "${LOG_FILE}"

    RUN_NUMBER=1

    while [ "${RUN_NUMBER}" -le "${TEST_COUNT}" ]; do
        run_single_test "${RUN_NUMBER}"

        if [ "${RUN_NUMBER}" -lt "${TEST_COUNT}" ]; then
            sleep "${TEST_INTERVAL}"
        fi

        RUN_NUMBER=$((RUN_NUMBER + 1))
    done

    create_summary
}

main "$@"
